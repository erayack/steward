defmodule Steward.StatusStore do
  @moduledoc "In-memory status projection store for processes/runs."
  use GenServer

  @type process_snapshot :: map()
  @type control_event :: map()

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

  @impl true
  def init(:ok), do: {:ok, %{processes: %{}, control_events: %{}}}

  @impl true
  def handle_cast({:upsert_process_snapshot, process_id, snapshot}, state) do
    next_processes = Map.put(state.processes, process_id, snapshot)
    {:noreply, %{state | processes: next_processes}}
  end

  @impl true
  def handle_cast({:record_control_event, process_id, event}, state) do
    events =
      state.control_events
      |> Map.get(process_id, [])
      |> Kernel.++([event])
      |> Enum.take(-100)

    next_events = Map.put(state.control_events, process_id, events)
    {:noreply, %{state | control_events: next_events}}
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
end
