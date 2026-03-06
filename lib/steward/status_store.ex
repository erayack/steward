defmodule Steward.StatusStore do
  @moduledoc "In-memory aggregation store for processes, runs, and membership snapshots."
  use GenServer

  require Logger

  alias Steward.AuditLog
  alias StewardWeb.ObservabilityPubSub

  @type process_snapshot :: map()
  @type control_event :: map()
  @type membership_snapshot :: %{nodes: map(), processes_by_node: map()}
  @type runs_snapshot :: map()
  @type audit_event :: map()
  @type aggregated_snapshot :: %{
          processes: %{optional(String.t()) => process_snapshot()},
          control_events: %{optional(String.t()) => [control_event()]},
          membership: membership_snapshot(),
          runs: runs_snapshot(),
          audit_events: [audit_event()],
          malformed_line_counts: %{optional(String.t()) => non_neg_integer()},
          updated_at_ms: integer()
        }

  @default_timeout 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec upsert_process_snapshot(Steward.Types.process_id(), process_snapshot()) :: :ok
  def upsert_process_snapshot(process_id, snapshot)
      when is_binary(process_id) and is_map(snapshot) do
    GenServer.cast(__MODULE__, {:upsert_process_snapshot, process_id, snapshot})
  end

  @spec record_control_event(Steward.Types.process_id(), atom(), map()) :: :ok
  def record_control_event(process_id, kind, payload \\ %{})
      when is_binary(process_id) and is_atom(kind) and is_map(payload) do
    event = %{
      ts_ms: System.monotonic_time(:millisecond),
      kind: kind,
      payload: payload
    }

    GenServer.cast(__MODULE__, {:record_control_event, process_id, event})
  end

  @spec refresh_membership(membership_snapshot()) :: :ok
  def refresh_membership(snapshot) when is_map(snapshot) do
    GenServer.cast(__MODULE__, {:refresh_membership, snapshot})
  end

  @spec refresh_runs(runs_snapshot()) :: :ok
  def refresh_runs(snapshot) when is_map(snapshot) do
    GenServer.cast(__MODULE__, {:refresh_runs, snapshot})
  end

  @spec get_process_snapshot(Steward.Types.process_id()) :: process_snapshot() | nil
  def get_process_snapshot(process_id) when is_binary(process_id) do
    GenServer.call(__MODULE__, {:get_process_snapshot, process_id})
  end

  @spec list_process_snapshots() :: [process_snapshot()]
  def list_process_snapshots do
    GenServer.call(__MODULE__, :list_process_snapshots)
  end

  @spec list_control_events(Steward.Types.process_id()) :: [control_event()]
  def list_control_events(process_id) when is_binary(process_id) do
    GenServer.call(__MODULE__, {:list_control_events, process_id})
  end

  @spec snapshot(timeout()) :: aggregated_snapshot()
  def snapshot(timeout \\ @default_timeout)

  def snapshot(timeout) when is_integer(timeout) and timeout > 0 do
    GenServer.call(__MODULE__, :snapshot, timeout)
  end

  @spec append_event(map()) :: :ok | {:error, term()}
  def append_event(event) when is_map(event) do
    GenServer.call(__MODULE__, {:append_event, event})
  end

  def append_event(_event), do: {:error, :invalid_event}

  @spec recent_events(non_neg_integer()) :: [audit_event()]
  def recent_events(limit) when is_integer(limit) and limit >= 0 do
    GenServer.call(__MODULE__, {:recent_events, limit})
  end

  @impl true
  def init(:ok) do
    now_ms = System.monotonic_time(:millisecond)

    initial_state = %{
      processes: %{},
      control_events: %{},
      membership: initial_membership_snapshot(),
      runs: initial_runs_snapshot(),
      audit_events: [],
      malformed_line_counts: %{},
      audit_seq: 0,
      updated_at_ms: now_ms
    }

    {:ok, initial_state}
  end

  @impl true
  def handle_cast({:upsert_process_snapshot, process_id, snapshot}, state) do
    next_state =
      state
      |> put_in([:processes, process_id], snapshot)
      |> touch_updated_at()
      |> maybe_broadcast_update()

    {:noreply, next_state}
  end

  @impl true
  def handle_cast({:record_control_event, process_id, event}, state) do
    events =
      state.control_events
      |> Map.get(process_id, [])
      |> Kernel.++([event])
      |> Enum.take(-100)

    next_state =
      state
      |> put_in([:control_events, process_id], events)
      |> touch_updated_at()
      |> maybe_broadcast_update()

    {:noreply, next_state}
  end

  @impl true
  def handle_cast({:refresh_membership, snapshot}, state) do
    next_state =
      state
      |> Map.put(:membership, normalize_membership_snapshot(snapshot))
      |> touch_updated_at()
      |> maybe_broadcast_update()

    {:noreply, next_state}
  end

  @impl true
  def handle_cast({:refresh_runs, snapshot}, state) do
    next_state =
      state
      |> Map.put(:runs, snapshot)
      |> touch_updated_at()
      |> maybe_broadcast_update()

    {:noreply, next_state}
  end

  @impl true
  def handle_call({:get_process_snapshot, process_id}, _from, state) do
    {:reply, Map.get(state.processes, process_id), state}
  end

  @impl true
  def handle_call(:list_process_snapshots, _from, state) do
    {:reply, Map.values(state.processes), state}
  end

  @impl true
  def handle_call({:list_control_events, process_id}, _from, state) do
    {:reply, Map.get(state.control_events, process_id, []), state}
  end

  @impl true
  def handle_call({:append_event, event}, _from, state) do
    now = DateTime.utc_now()
    ts_ms = DateTime.to_unix(now, :millisecond)
    next_seq = Map.get(state, :audit_seq, 0) + 1

    normalized_event =
      event
      |> Map.put_new(:event_id, next_seq)
      |> Map.put_new(:ts, DateTime.to_iso8601(now))
      |> Map.put_new(:ts_ms, ts_ms)
      |> Map.put_new(:node, node())

    maybe_persist_audit_event(normalized_event)

    next_state =
      state
      |> Map.put(:audit_seq, next_seq)
      |> Map.update(:audit_events, [normalized_event], fn events ->
        (events ++ [normalized_event]) |> Enum.take(-audit_max_events())
      end)
      |> maybe_increment_malformed_counter(normalized_event)
      |> touch_updated_at()
      |> maybe_broadcast_update()

    {:reply, :ok, next_state}
  end

  def handle_call({:recent_events, limit}, _from, state) do
    events =
      state
      |> Map.get(:audit_events, [])
      |> Enum.take(-limit)
      |> Enum.reverse()

    {:reply, events, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state, state}
  end

  defp touch_updated_at(state) do
    %{state | updated_at_ms: System.monotonic_time(:millisecond)}
  end

  defp maybe_broadcast_update(state) do
    ObservabilityPubSub.broadcast_update(%{updated_at_ms: state.updated_at_ms})
    state
  rescue
    _ -> state
  end

  defp maybe_persist_audit_event(event) do
    case AuditLog.append_event(event) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to append audit event to sink: #{inspect(reason)}")
    end
  end

  defp maybe_increment_malformed_counter(state, event) do
    if malformed_event?(event) and is_binary(event[:process_id]) do
      counters = Map.get(state, :malformed_line_counts, %{})

      next_counters =
        counters
        |> Map.put_new(event.process_id, 0)
        |> Map.update!(event.process_id, &(&1 + 1))

      Map.put(state, :malformed_line_counts, next_counters)
    else
      state
    end
  end

  defp malformed_event?(event) do
    case Map.get(event, :event) do
      :protocol_malformed_line -> true
      "protocol_malformed_line" -> true
      _ -> false
    end
  end

  defp audit_max_events do
    Application.get_env(:steward, :audit, [])
    |> Keyword.get(:max_events, 2_000)
  end

  defp initial_membership_snapshot do
    case Process.whereis(Steward.ClusterMembership) do
      nil -> %{nodes: %{}, processes_by_node: %{}}
      _pid -> Steward.ClusterMembership.snapshot()
    end
  end

  defp initial_runs_snapshot do
    case Process.whereis(Steward.RunRegistry) do
      nil -> %{active_runs: %{}, completed_runs: %{}, counts: %{}}
      _pid -> Steward.RunRegistry.snapshot()
    end
  end

  defp normalize_membership_snapshot(snapshot) do
    %{
      nodes: Map.get(snapshot, :nodes, %{}),
      processes_by_node: Map.get(snapshot, :processes_by_node, %{})
    }
  end
end
