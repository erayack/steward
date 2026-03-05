defmodule Steward.PortWorker do
  @moduledoc "Per-process worker that owns the port lifecycle and JSONL stream handling."
  use GenServer

  require Logger

  alias Steward.{QuarantinePolicy, StatusStore}

  @port_line_bytes 1_048_576
  @default_quarantine [max_crashes: 3, window_ms: 60_000, cooldown_ms: 120_000]

  @type quarantine_cfg :: [
          max_crashes: pos_integer(),
          window_ms: pos_integer(),
          cooldown_ms: pos_integer()
        ]

  @type state :: %{
          process_id: Steward.Types.process_id(),
          binary_path: String.t(),
          args: [String.t()],
          port: port() | nil,
          status: Steward.Types.proc_status(),
          last_heartbeat_at: DateTime.t() | nil,
          last_event: map() | nil,
          restart_count: non_neg_integer(),
          crash_timestamps_ms: [integer()],
          quarantined_until_ms: integer() | nil,
          cooldown_ref: reference() | nil,
          line_buffer: binary()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, init_opts} = Keyword.pop(opts, :name)

    case name do
      nil -> GenServer.start_link(__MODULE__, init_opts)
      _ -> GenServer.start_link(__MODULE__, init_opts, name: name)
    end
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @spec send_command(GenServer.server(), map()) :: :ok | {:error, term()}
  def send_command(server, command) when is_map(command) do
    GenServer.call(server, {:send_command, command})
  end

  @impl true
  def init(opts) do
    process_id = Keyword.fetch!(opts, :process_id)
    binary_path = Keyword.fetch!(opts, :binary_path)
    args = Keyword.get(opts, :args, [])

    state = %{
      process_id: process_id,
      binary_path: binary_path,
      args: args,
      port: nil,
      status: :down,
      last_heartbeat_at: nil,
      last_event: nil,
      restart_count: 0,
      crash_timestamps_ms: [],
      quarantined_until_ms: nil,
      cooldown_ref: nil,
      line_buffer: ""
    }

    case open_port(state.binary_path, state.args) do
      {:ok, port, os_pid} ->
        now = DateTime.utc_now()

        next_state =
          state
          |> Map.put(:port, port)
          |> Map.put(:status, :up)
          |> Map.put(:last_event, %{type: :port_opened, os_pid: os_pid, at: now})
          |> publish_snapshot()

        {:ok, next_state}

      {:error, reason} ->
        Logger.error("failed to start process #{process_id}: #{inspect(reason)}")
        {:stop, {:port_open_failed, reason}}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_from_state(state), state}

  @impl true
  def handle_call({:send_command, _command}, _from, %{port: nil} = state) do
    {:reply, {:error, :port_not_available}, state}
  end

  def handle_call({:send_command, _command}, _from, %{status: :quarantined} = state) do
    {:reply, {:error, :quarantined}, state}
  end

  def handle_call({:send_command, command}, _from, state) do
    payload = encode_command_payload(command)

    try do
      Port.command(state.port, payload)

      now = DateTime.utc_now()

      next_state =
        state
        |> Map.put(:last_event, %{type: :command_dispatched, at: now, payload: command})
        |> publish_snapshot()

      {:reply, :ok, next_state}
    rescue
      ArgumentError ->
        {:reply, {:error, :port_command_failed}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | line_buffer: state.line_buffer <> to_string(chunk)}}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    raw_line = state.line_buffer <> to_string(line)
    cleaned = String.trim(raw_line)
    state = %{state | line_buffer: ""}

    next_state =
      case cleaned do
        "" ->
          state

        _ ->
          process_line(cleaned, state)
      end

    {:noreply, next_state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    now_ms = System.monotonic_time(:millisecond)
    qcfg = quarantine_config()

    StatusStore.record_control_event(state.process_id, :port_exit, %{
      exit_code: code,
      at_ms: now_ms
    })

    base_state = state_after_exit(state, code, now_ms)

    if code == 0 do
      {:noreply, restart_with_logging(base_state)}
    else
      case QuarantinePolicy.classify_crash(base_state.crash_timestamps_ms, now_ms, qcfg) do
        {:quarantine, cooldown_ms, crash_timestamps_ms} ->
          quarantined_until_ms = now_ms + cooldown_ms

          next_state =
            base_state
            |> Map.put(:status, :restarting)
            |> Map.put(:restart_count, base_state.restart_count + 1)
            |> Map.put(:crash_timestamps_ms, crash_timestamps_ms)
            |> quarantine_state(cooldown_ms, quarantined_until_ms)

          StatusStore.record_control_event(state.process_id, :quarantined, %{
            cooldown_ms: cooldown_ms,
            quarantined_until_ms: quarantined_until_ms
          })

          {:noreply, next_state}

        {:restart, crash_timestamps_ms} ->
          restart_state =
            base_state
            |> Map.put(:status, :restarting)
            |> Map.put(:restart_count, base_state.restart_count + 1)
            |> Map.put(:crash_timestamps_ms, crash_timestamps_ms)

          {:noreply, restart_with_logging(restart_state)}
      end
    end
  end

  def handle_info(:cooldown_elapsed, %{status: :quarantined} = state) do
    base_state =
      state
      |> Map.put(:cooldown_ref, nil)
      |> Map.put(:quarantined_until_ms, nil)
      |> Map.put(:status, :restarting)
      |> Map.put(:last_event, %{
        type: :cooldown_elapsed,
        at_ms: System.monotonic_time(:millisecond)
      })
      |> publish_snapshot()

    case restart_port(base_state) do
      {:ok, next_state} ->
        StatusStore.record_control_event(state.process_id, :quarantine_released, %{})
        {:noreply, next_state}

      {:error, reason, next_state} ->
        StatusStore.record_control_event(state.process_id, :restart_failed, %{
          reason: inspect(reason)
        })

        {:noreply, next_state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp process_line(line, state) do
    case parse_envelope(line) do
      {:ok, envelope} -> apply_envelope(envelope, line, state)
      :malformed -> emit_malformed(line, state)
    end
  end

  defp apply_envelope(envelope, raw_line, state) do
    kind = envelope.kind
    ts = envelope.ts
    fields = envelope.fields

    state =
      state
      |> Map.put(:last_event, %{
        type: :telemetry,
        kind: kind,
        raw: raw_line,
        at: DateTime.utc_now()
      })
      |> maybe_set_heartbeat(kind, ts)
      |> maybe_mark_up()
      |> publish_snapshot()

    StatusStore.record_control_event(state.process_id, :telemetry, %{kind: kind, fields: fields})
    state
  end

  defp maybe_set_heartbeat(state, :heartbeat, ts),
    do: %{state | last_heartbeat_at: ts || DateTime.utc_now()}

  defp maybe_set_heartbeat(state, _kind, _ts), do: state

  defp maybe_mark_up(%{status: :up} = state), do: state
  defp maybe_mark_up(state), do: %{state | status: :up}

  @doc false
  @spec parse_envelope(binary()) ::
          {:ok, %{kind: Steward.Types.port_kind(), ts: DateTime.t() | nil, fields: map()}}
          | :malformed
  def parse_envelope(line) do
    case Jason.decode(line) do
      {:ok, %{} = envelope} ->
        {:ok,
         %{
           kind: normalize_kind(Map.get(envelope, "kind")),
           ts: parse_ts(Map.get(envelope, "ts")),
           fields: normalize_fields(Map.get(envelope, "fields"))
         }}

      {:ok, _other} ->
        :malformed

      {:error, _reason} ->
        :malformed
    end
  end

  defp emit_malformed(raw_line, state) do
    StatusStore.record_control_event(state.process_id, :malformed, %{payload: raw_line})

    state
    |> Map.put(:last_event, %{type: :malformed, raw: raw_line, at: DateTime.utc_now()})
    |> publish_snapshot()
  end

  defp open_port(binary_path, args) do
    path =
      binary_path
      |> Path.expand()
      |> String.to_charlist()

    argv = Enum.map(args, &String.to_charlist/1)

    port =
      Port.open(
        {:spawn_executable, path},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          line: @port_line_bytes,
          args: argv
        ]
      )

    os_pid =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, value} -> value
        _ -> nil
      end

    {:ok, port, os_pid}
  rescue
    error -> {:error, error}
  end

  @spec quarantine_config() :: quarantine_cfg()
  defp quarantine_config do
    Application.get_env(:steward, :quarantine, @default_quarantine)
  end

  @spec state_after_exit(state(), integer(), integer()) :: state()
  defp state_after_exit(state, code, now_ms) do
    state
    |> Map.put(:port, nil)
    |> Map.put(:last_event, %{type: :port_exit, exit_code: code, at_ms: now_ms})
  end

  @spec quarantine_state(state(), pos_integer(), integer()) :: state()
  defp quarantine_state(state, cooldown_ms, quarantined_until_ms) do
    cooldown_ref = Process.send_after(self(), :cooldown_elapsed, cooldown_ms)

    state
    |> maybe_cancel_cooldown()
    |> Map.put(:status, :quarantined)
    |> Map.put(:quarantined_until_ms, quarantined_until_ms)
    |> Map.put(:cooldown_ref, cooldown_ref)
    |> publish_snapshot()
  end

  defp restart_port(state) do
    case open_port(state.binary_path, state.args) do
      {:ok, port, os_pid} ->
        now = DateTime.utc_now()

        next_state =
          state
          |> Map.put(:port, port)
          |> Map.put(:status, :up)
          |> Map.put(:last_event, %{type: :port_restarted, os_pid: os_pid, at: now})
          |> publish_snapshot()

        StatusStore.record_control_event(state.process_id, :restarted, %{os_pid: os_pid})
        {:ok, next_state}

      {:error, reason} ->
        next_state =
          state
          |> Map.put(:status, :down)
          |> Map.put(:last_event, %{
            type: :restart_failed,
            reason: inspect(reason),
            at: DateTime.utc_now()
          })
          |> publish_snapshot()

        {:error, reason, next_state}
    end
  end

  defp restart_with_logging(state) do
    case restart_port(state) do
      {:ok, next_state} ->
        next_state

      {:error, reason, next_state} ->
        StatusStore.record_control_event(state.process_id, :restart_failed, %{
          reason: inspect(reason)
        })

        next_state
    end
  end

  defp maybe_cancel_cooldown(%{cooldown_ref: nil} = state), do: state

  defp maybe_cancel_cooldown(state) do
    Process.cancel_timer(state.cooldown_ref)
    %{state | cooldown_ref: nil}
  end

  @doc false
  def normalize_kind(kind) when kind in [:heartbeat, :metric, :event, :error], do: kind

  def normalize_kind(kind) when is_binary(kind) do
    case kind do
      "heartbeat" -> :heartbeat
      "metric" -> :metric
      "event" -> :event
      "error" -> :error
      _ -> :event
    end
  end

  def normalize_kind(_), do: :event

  @doc false
  def parse_ts(nil), do: nil

  def parse_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  def parse_ts(_), do: nil

  @doc false
  def normalize_fields(fields) when is_map(fields), do: fields
  def normalize_fields(_), do: %{}

  @doc false
  def encode_command_payload(command) do
    command
    |> normalize_command()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp normalize_command(%{"kind" => _} = command), do: command
  defp normalize_command(%{kind: _} = command), do: command

  defp normalize_command(command) do
    %{
      "kind" => "command",
      "fields" => command
    }
  end

  defp publish_snapshot(state) do
    StatusStore.upsert_process_snapshot(state.process_id, snapshot_from_state(state))
    state
  end

  defp snapshot_from_state(state) do
    %{
      process_id: state.process_id,
      binary_path: state.binary_path,
      args: state.args,
      status: state.status,
      last_heartbeat_at: state.last_heartbeat_at,
      last_event: state.last_event,
      restart_count: state.restart_count,
      crash_timestamps_ms: state.crash_timestamps_ms,
      quarantined_until_ms: state.quarantined_until_ms
    }
  end
end
