defmodule Steward.PortWorker do
  @moduledoc "Per-process worker that owns the port lifecycle and JSONL stream handling."
  use GenServer

  require Logger

  alias Steward.{QuarantinePolicy, StatusStore}

  @port_line_bytes 1_048_576
  @default_quarantine [max_crashes: 3, window_ms: 60_000, cooldown_ms: 120_000]
  @default_hot_swap [
    readiness_mode: :port_open,
    readiness_timeout_ms: 15_000,
    graceful_shutdown_timeout_ms: 10_000,
    fallback_on_candidate_exit: true
  ]

  @type quarantine_cfg :: [
          max_crashes: pos_integer(),
          window_ms: pos_integer(),
          cooldown_ms: pos_integer()
        ]

  @type readiness_mode :: :port_open | :heartbeat

  @type candidate_state :: %{
          port: port(),
          binary_path: String.t(),
          args: [String.t()],
          os_pid: integer() | nil,
          readiness_mode: readiness_mode(),
          swap_opts: map(),
          started_at: DateTime.t()
        }

  @type draining_state :: %{
          port: port(),
          force_close_ref: reference(),
          started_at: DateTime.t()
        }

  @type state :: %{
          process_id: Steward.Types.process_id(),
          binary_path: String.t(),
          args: [String.t()],
          port: port() | nil,
          status: Steward.Types.proc_status(),
          last_heartbeat_at: DateTime.t() | nil,
          last_event: map() | nil,
          metrics: map(),
          metric_recent: map(),
          metrics_updated_at: DateTime.t() | nil,
          restart_count: non_neg_integer(),
          crash_timestamps_ms: [integer()],
          quarantined_until_ms: integer() | nil,
          cooldown_ref: reference() | nil,
          line_buffers: %{optional(port()) => binary()},
          candidate: candidate_state() | nil,
          draining: draining_state() | nil,
          upgrade_state: :idle | :starting | :waiting_ready | :draining | :rolled_back | :failed,
          upgrade_timeout_ref: reference() | nil,
          binary_generation: non_neg_integer(),
          active_binary_path: String.t()
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

  @spec hot_swap(GenServer.server(), String.t(), [String.t()], keyword()) ::
          :ok | {:error, term()}
  def hot_swap(server, binary_path, args, opts \\ [])
      when is_binary(binary_path) and is_list(args) and is_list(opts) do
    timeout = Keyword.get(opts, :call_timeout, 30_000)
    GenServer.call(server, {:hot_swap, binary_path, args, opts}, timeout)
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
      metrics: %{},
      metric_recent: %{},
      metrics_updated_at: nil,
      restart_count: 0,
      crash_timestamps_ms: [],
      quarantined_until_ms: nil,
      cooldown_ref: nil,
      line_buffers: %{},
      candidate: nil,
      draining: nil,
      upgrade_state: :idle,
      upgrade_timeout_ref: nil,
      binary_generation: 1,
      active_binary_path: binary_path
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

        append_audit_event(state.process_id, :worker_started, %{os_pid: os_pid, at: now})
        {:ok, next_state}

      {:error, reason} ->
        Logger.error("failed to start process #{process_id}: #{inspect(reason)}")
        {:stop, {:port_open_failed, reason}}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_from_state(state), state}

  @impl true
  def handle_call({:hot_swap, _binary_path, _args, _opts}, _from, %{port: nil} = state) do
    {:reply, {:error, :port_not_available}, state}
  end

  def handle_call({:hot_swap, _binary_path, _args, _opts}, _from, %{status: :quarantined} = state) do
    {:reply, {:error, :quarantined}, state}
  end

  def handle_call({:hot_swap, _binary_path, _args, _opts}, _from, state)
      when not is_nil(state.candidate) do
    {:reply, {:error, :upgrade_in_progress}, state}
  end

  def handle_call({:hot_swap, _binary_path, _args, _opts}, _from, state)
      when not is_nil(state.draining) do
    {:reply, {:error, :upgrade_in_progress}, state}
  end

  def handle_call({:hot_swap, binary_path, args, opts}, _from, state) do
    with :ok <- ensure_hot_swap_enabled(),
         :ok <- validate_binary_path(binary_path),
         :ok <- validate_args(args),
         {:ok, swap_opts} <- normalize_hot_swap_opts(opts),
         {:ok, next_state} <- start_hot_swap(state, binary_path, args, swap_opts) do
      {:reply, :ok, next_state}
    else
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

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
  def handle_info({port, {:data, {:noeol, chunk}}}, state) do
    if tracked_port?(state, port) do
      {:noreply, append_port_buffer(state, port, chunk)}
    else
      {:noreply, state}
    end
  end

  def handle_info({port, {:data, {:eol, line}}}, state) do
    if tracked_port?(state, port) do
      {raw_line, buffered_state} = consume_buffered_line(state, port, line)
      cleaned = String.trim(raw_line)

      next_state =
        cond do
          cleaned == "" ->
            buffered_state

          active_port?(state, port) ->
            process_line(cleaned, buffered_state)

          candidate_port?(state, port) ->
            process_candidate_line(cleaned, buffered_state)

          true ->
            buffered_state
        end

      {:noreply, next_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, code}}, state) do
    cond do
      active_port?(state, port) ->
        {:noreply, handle_active_port_exit(state, code, port)}

      candidate_port?(state, port) ->
        {:noreply, handle_candidate_exit(state, code, port)}

      draining_port?(state, port) ->
        {:noreply, handle_draining_exit(state, code, port)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:candidate_readiness_timeout, candidate_port}, state) do
    if candidate_port?(state, candidate_port) and state.upgrade_state == :waiting_ready do
      next_state =
        rollback_candidate(state, :candidate_readiness_timeout)
        |> Map.put(:upgrade_state, :failed)
        |> publish_snapshot()

      {:noreply, next_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:force_close_draining, draining_port}, state) do
    if draining_port?(state, draining_port) do
      force_close_port(draining_port)
    end

    {:noreply, state}
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
        append_audit_event(state.process_id, :worker_quarantine_exited, %{})
        {:noreply, next_state}

      {:error, reason, next_state} ->
        StatusStore.record_control_event(state.process_id, :restart_failed, %{
          reason: inspect(reason)
        })

        append_audit_event(state.process_id, :worker_restart_failed, %{reason: inspect(reason)})

        {:noreply, next_state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_hot_swap(state, binary_path, args, swap_opts) do
    case open_port(binary_path, args) do
      {:ok, candidate_port, os_pid} ->
        now = DateTime.utc_now()

        started_state =
          state
          |> Map.put(:candidate, %{
            port: candidate_port,
            binary_path: binary_path,
            args: args,
            os_pid: os_pid,
            readiness_mode: swap_opts.readiness_mode,
            swap_opts: swap_opts,
            started_at: now
          })
          |> Map.put(:upgrade_state, :starting)
          |> Map.put(:last_event, %{
            type: :hot_swap_candidate_opened,
            os_pid: os_pid,
            at: now,
            readiness_mode: swap_opts.readiness_mode
          })

        StatusStore.record_control_event(state.process_id, :hot_swap_candidate_opened, %{
          os_pid: os_pid,
          readiness_mode: swap_opts.readiness_mode
        })

        append_audit_event(state.process_id, :worker_hot_swap_candidate_opened, %{
          os_pid: os_pid,
          readiness_mode: swap_opts.readiness_mode,
          binary_path: binary_path,
          args: args
        })

        if swap_opts.readiness_mode == :port_open do
          {:ok, cutover_to_candidate(started_state, swap_opts)}
        else
          timeout_ref =
            Process.send_after(
              self(),
              {:candidate_readiness_timeout, candidate_port},
              swap_opts.readiness_timeout_ms
            )

          {:ok,
           started_state
           |> Map.put(:upgrade_state, :waiting_ready)
           |> Map.put(:upgrade_timeout_ref, timeout_ref)
           |> publish_snapshot()}
        end

      {:error, reason} ->
        next_state =
          state
          |> Map.put(:upgrade_state, :failed)
          |> Map.put(:last_event, %{type: :hot_swap_open_failed, reason: inspect(reason)})
          |> publish_snapshot()

        StatusStore.record_control_event(state.process_id, :hot_swap_open_failed, %{
          reason: inspect(reason)
        })

        append_audit_event(state.process_id, :worker_hot_swap_open_failed, %{
          reason: inspect(reason),
          binary_path: binary_path,
          args: args
        })

        {:error, reason, next_state}
    end
  end

  defp cutover_to_candidate(%{candidate: nil} = state, _swap_opts), do: state

  defp cutover_to_candidate(state, swap_opts) do
    candidate = state.candidate
    old_port = state.port
    now = DateTime.utc_now()

    upgraded_state =
      state
      |> maybe_cancel_upgrade_timeout()
      |> Map.put(:port, candidate.port)
      |> Map.put(:binary_path, candidate.binary_path)
      |> Map.put(:args, candidate.args)
      |> Map.put(:candidate, nil)
      |> Map.put(:active_binary_path, candidate.binary_path)
      |> Map.put(:binary_generation, state.binary_generation + 1)
      |> Map.put(:upgrade_state, :draining)
      |> Map.put(:last_event, %{
        type: :hot_swap_cutover,
        at: now,
        os_pid: candidate.os_pid,
        readiness_mode: candidate.readiness_mode
      })

    StatusStore.record_control_event(state.process_id, :hot_swap_cutover, %{
      os_pid: candidate.os_pid,
      readiness_mode: candidate.readiness_mode
    })

    append_audit_event(state.process_id, :worker_hot_swap_cutover, %{
      at: now,
      os_pid: candidate.os_pid,
      readiness_mode: candidate.readiness_mode,
      binary_path: candidate.binary_path,
      args: candidate.args
    })

    next_state =
      if is_port(old_port) do
        force_close_ref =
          Process.send_after(
            self(),
            {:force_close_draining, old_port},
            swap_opts.graceful_shutdown_timeout_ms
          )

        maybe_request_port_shutdown(old_port)

        upgraded_state
        |> Map.put(:draining, %{port: old_port, force_close_ref: force_close_ref, started_at: now})
      else
        upgraded_state
        |> Map.put(:draining, nil)
        |> Map.put(:upgrade_state, :idle)
      end

    publish_snapshot(next_state)
  end

  defp process_candidate_line(line, state) do
    case parse_envelope(line) do
      {:ok, %{kind: :heartbeat}} ->
        maybe_cutover_on_heartbeat(state)

      {:ok, _envelope} ->
        state

      :malformed ->
        state
    end
  end

  defp maybe_cutover_on_heartbeat(%{upgrade_state: :waiting_ready, candidate: candidate} = state)
       when not is_nil(candidate) and candidate.readiness_mode == :heartbeat do
    StatusStore.record_control_event(state.process_id, :hot_swap_candidate_ready, %{
      mode: :heartbeat
    })

    append_audit_event(state.process_id, :worker_hot_swap_candidate_ready, %{mode: :heartbeat})

    cutover_to_candidate(state, candidate.swap_opts)
  end

  defp maybe_cutover_on_heartbeat(state), do: state

  defp rollback_candidate(%{candidate: nil} = state, _reason),
    do: maybe_cancel_upgrade_timeout(state)

  defp rollback_candidate(state, reason) do
    state = maybe_cancel_upgrade_timeout(state)

    force_close_port(state.candidate.port)

    StatusStore.record_control_event(state.process_id, :hot_swap_rollback, %{
      reason: inspect(reason)
    })

    append_audit_event(state.process_id, :worker_hot_swap_rollback, %{reason: inspect(reason)})

    state
    |> Map.put(:candidate, nil)
    |> Map.put(:upgrade_state, :rolled_back)
    |> Map.put(:last_event, %{
      type: :hot_swap_rollback,
      reason: inspect(reason),
      at: DateTime.utc_now()
    })
    |> drop_line_buffer(state.candidate.port)
  end

  defp handle_candidate_exit(state, code, candidate_port) do
    StatusStore.record_control_event(state.process_id, :hot_swap_candidate_exit, %{
      exit_code: code
    })

    append_audit_event(state.process_id, :worker_hot_swap_candidate_exit, %{exit_code: code})
    fallback_on_candidate_exit? = candidate_fallback_on_exit?(state)

    if state.upgrade_state in [:starting, :waiting_ready] do
      failed_state =
        rollback_candidate(state, {:candidate_exit, code})
        |> Map.put(:upgrade_state, :failed)
        |> publish_snapshot()

      if fallback_on_candidate_exit? do
        failed_state
      else
        handle_active_port_exit(failed_state, max(code, 1), failed_state.port)
      end
    else
      state
      |> Map.put(:candidate, nil)
      |> drop_line_buffer(candidate_port)
      |> publish_snapshot()
    end
  end

  defp handle_draining_exit(state, code, draining_port) do
    status = if code == 0, do: :hot_swap_complete, else: :hot_swap_drain_exit

    StatusStore.record_control_event(state.process_id, status, %{exit_code: code})

    append_audit_event(state.process_id, :worker_hot_swap_drain_exit, %{
      status: status,
      exit_code: code
    })

    state
    |> maybe_cancel_drain_timer()
    |> Map.put(:draining, nil)
    |> Map.put(:upgrade_state, :idle)
    |> Map.put(:last_event, %{type: status, exit_code: code, at: DateTime.utc_now()})
    |> drop_line_buffer(draining_port)
    |> publish_snapshot()
  end

  defp handle_active_port_exit(state, code, active_port) do
    now_ms = System.monotonic_time(:millisecond)
    qcfg = quarantine_config()

    StatusStore.record_control_event(state.process_id, :port_exit, %{
      exit_code: code,
      at_ms: now_ms
    })

    append_audit_event(state.process_id, :worker_port_exit, %{exit_code: code, at_ms: now_ms})

    base_state =
      state
      |> cleanup_upgrade_ports()
      |> state_after_exit(code, now_ms)
      |> drop_line_buffer(active_port)

    if code == 0 do
      restart_with_logging(base_state)
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

          append_audit_event(state.process_id, :worker_quarantine_entered, %{
            cooldown_ms: cooldown_ms,
            quarantined_until_ms: quarantined_until_ms
          })

          next_state

        {:restart, crash_timestamps_ms} ->
          restart_state =
            base_state
            |> Map.put(:status, :restarting)
            |> Map.put(:restart_count, base_state.restart_count + 1)
            |> Map.put(:crash_timestamps_ms, crash_timestamps_ms)

          restart_with_logging(restart_state)
      end
    end
  end

  defp cleanup_upgrade_ports(state) do
    state
    |> maybe_cancel_upgrade_timeout()
    |> maybe_close_candidate_port()
    |> maybe_close_draining_port()
    |> maybe_cancel_drain_timer()
    |> Map.put(:candidate, nil)
    |> Map.put(:draining, nil)
    |> Map.put(:upgrade_state, :idle)
  end

  defp maybe_close_candidate_port(%{candidate: nil} = state), do: state

  defp maybe_close_candidate_port(state) do
    force_close_port(state.candidate.port)
    drop_line_buffer(state, state.candidate.port)
  end

  defp maybe_close_draining_port(%{draining: nil} = state), do: state

  defp maybe_close_draining_port(state) do
    force_close_port(state.draining.port)
    drop_line_buffer(state, state.draining.port)
  end

  defp candidate_fallback_on_exit?(%{candidate: %{swap_opts: swap_opts}})
       when is_map(swap_opts) do
    Map.get(swap_opts, :fallback_on_candidate_exit, true)
  end

  defp candidate_fallback_on_exit?(_state), do: true

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
      |> maybe_project_metrics(kind, fields, ts)
      |> maybe_mark_up()
      |> publish_snapshot()

    StatusStore.record_control_event(state.process_id, :telemetry, %{kind: kind, fields: fields})
    state
  end

  defp maybe_set_heartbeat(state, :heartbeat, ts),
    do: %{state | last_heartbeat_at: ts || DateTime.utc_now()}

  defp maybe_set_heartbeat(state, _kind, _ts), do: state

  defp maybe_project_metrics(state, :metric, fields, ts) when is_map(fields) do
    projected_at = ts || DateTime.utc_now()

    {metrics, metric_recent} =
      fields
      |> normalize_metric_fields()
      |> Enum.reduce({state.metrics, state.metric_recent}, fn {key, value}, acc ->
        project_metric_field(key, value, acc)
      end)

    state
    |> Map.put(:metrics, metrics)
    |> Map.put(:metric_recent, metric_recent)
    |> Map.put(:metrics_updated_at, projected_at)
  end

  defp maybe_project_metrics(state, _kind, _fields, _ts), do: state

  defp project_metric_field(key, value, {metrics_acc, recent_acc}) do
    if metric_key_saturated?(metrics_acc, key) do
      {metrics_acc, recent_acc}
    else
      {Map.put(metrics_acc, key, value), maybe_push_metric_sample(recent_acc, key, value)}
    end
  end

  defp metric_key_saturated?(metrics_acc, key) do
    map_size(metrics_acc) >= metric_max_keys() and not Map.has_key?(metrics_acc, key)
  end

  defp maybe_push_metric_sample(recent_acc, key, value) when is_integer(value) or is_float(value),
    do: push_metric_sample(recent_acc, key, value * 1.0)

  defp maybe_push_metric_sample(recent_acc, _key, _value), do: recent_acc

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

    append_audit_event(state.process_id, :protocol_malformed_line, %{
      payload: raw_line,
      bytes: byte_size(raw_line)
    })

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

  defp hot_swap_config do
    Application.get_env(:steward, :hot_swap, @default_hot_swap)
  end

  defp hot_swap_enabled? do
    hot_swap_config()
    |> Keyword.get(:enabled, false)
  end

  defp ensure_hot_swap_enabled do
    if hot_swap_enabled?(), do: :ok, else: {:error, :hot_swap_disabled}
  end

  defp normalize_hot_swap_opts(opts) do
    config = Keyword.merge(hot_swap_config(), opts)

    with {:ok, readiness_mode} <- normalize_readiness_mode(Keyword.get(config, :readiness_mode)),
         {:ok, readiness_timeout_ms} <-
           normalize_positive_integer(Keyword.get(config, :readiness_timeout_ms)),
         {:ok, graceful_shutdown_timeout_ms} <-
           normalize_positive_integer(Keyword.get(config, :graceful_shutdown_timeout_ms)) do
      {:ok,
       %{
         readiness_mode: readiness_mode,
         readiness_timeout_ms: readiness_timeout_ms,
         graceful_shutdown_timeout_ms: graceful_shutdown_timeout_ms,
         fallback_on_candidate_exit:
           normalize_boolean(Keyword.get(config, :fallback_on_candidate_exit), true)
       }}
    end
  end

  defp normalize_readiness_mode(mode) when mode in [:port_open, :heartbeat], do: {:ok, mode}
  defp normalize_readiness_mode("port_open"), do: {:ok, :port_open}
  defp normalize_readiness_mode("heartbeat"), do: {:ok, :heartbeat}
  defp normalize_readiness_mode(_), do: {:error, :invalid_readiness_mode}

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp normalize_positive_integer(_), do: {:error, :invalid_timeout}

  defp normalize_boolean(value, _default) when is_boolean(value), do: value
  defp normalize_boolean(_value, default), do: default

  defp validate_binary_path(binary_path) when is_binary(binary_path) and binary_path != "",
    do: :ok

  defp validate_binary_path(_), do: {:error, :invalid_binary_path}

  defp validate_args(args) when is_list(args) do
    if Enum.all?(args, &is_binary/1), do: :ok, else: {:error, :invalid_args}
  end

  defp validate_args(_), do: {:error, :invalid_args}

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
          |> Map.put(:upgrade_state, :idle)
          |> Map.put(:active_binary_path, state.binary_path)
          |> Map.put(:last_event, %{type: :port_restarted, os_pid: os_pid, at: now})
          |> publish_snapshot()

        StatusStore.record_control_event(state.process_id, :restarted, %{os_pid: os_pid})
        append_audit_event(state.process_id, :worker_restarted, %{os_pid: os_pid})
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

        append_audit_event(state.process_id, :worker_restart_failed, %{reason: inspect(reason)})

        next_state
    end
  end

  defp maybe_cancel_cooldown(%{cooldown_ref: nil} = state), do: state

  defp maybe_cancel_cooldown(state) do
    Process.cancel_timer(state.cooldown_ref)
    %{state | cooldown_ref: nil}
  end

  defp maybe_cancel_upgrade_timeout(%{upgrade_timeout_ref: nil} = state), do: state

  defp maybe_cancel_upgrade_timeout(state) do
    Process.cancel_timer(state.upgrade_timeout_ref)
    %{state | upgrade_timeout_ref: nil}
  end

  defp maybe_cancel_drain_timer(%{draining: nil} = state), do: state

  defp maybe_cancel_drain_timer(state) do
    Process.cancel_timer(state.draining.force_close_ref)
    state
  end

  defp maybe_request_port_shutdown(port) do
    payload = Jason.encode!(%{"kind" => "shutdown", "fields" => %{"graceful" => true}}) <> "\n"

    Port.command(port, payload)
    :ok
  rescue
    _ -> :ok
  end

  defp force_close_port(port) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp force_close_port(_), do: :ok

  defp append_port_buffer(state, port, chunk) do
    chunk_binary = to_string(chunk)
    current = Map.get(state.line_buffers, port, "")
    put_in(state, [:line_buffers, port], current <> chunk_binary)
  end

  defp consume_buffered_line(state, port, line) do
    current = Map.get(state.line_buffers, port, "")
    raw_line = current <> to_string(line)
    {raw_line, drop_line_buffer(state, port)}
  end

  defp drop_line_buffer(state, port),
    do: %{state | line_buffers: Map.delete(state.line_buffers, port)}

  defp tracked_port?(state, port), do: active_port?(state, port) or candidate_port?(state, port)

  defp active_port?(state, port), do: not is_nil(state.port) and state.port == port

  defp candidate_port?(state, port) do
    not is_nil(state.candidate) and state.candidate.port == port
  end

  defp draining_port?(state, port), do: not is_nil(state.draining) and state.draining.port == port

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
      metrics: state.metrics,
      metric_recent: state.metric_recent,
      metrics_updated_at: state.metrics_updated_at,
      restart_count: state.restart_count,
      crash_timestamps_ms: state.crash_timestamps_ms,
      quarantined_until_ms: state.quarantined_until_ms,
      upgrade_state: state.upgrade_state,
      active_binary_path: state.active_binary_path,
      binary_generation: state.binary_generation
    }
  end

  defp metric_window_size do
    case Application.get_env(:steward, :metrics, []) |> Keyword.get(:window_size, 10) do
      value when is_integer(value) and value > 0 -> value
      _ -> 10
    end
  end

  defp metric_max_keys do
    case Application.get_env(:steward, :metrics, []) |> Keyword.get(:max_keys_per_process, 64) do
      value when is_integer(value) and value > 0 -> value
      _ -> 64
    end
  end

  defp normalize_metric_fields(fields) when is_map(fields) do
    Enum.reduce(fields, %{}, fn
      {key, value}, acc when is_binary(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_atom(key) ->
        Map.put(acc, Atom.to_string(key), value)

      _entry, acc ->
        acc
    end)
  end

  defp push_metric_sample(metric_recent, key, value) do
    window_size = metric_window_size()
    series = Map.get(metric_recent, key, [])
    Map.put(metric_recent, key, Enum.take(series ++ [value], -window_size))
  end

  defp append_audit_event(process_id, event, payload) do
    _ =
      StatusStore.append_event(%{
        entity: :worker,
        event: event,
        process_id: process_id,
        payload: payload
      })

    :ok
  rescue
    _ -> :ok
  end
end
