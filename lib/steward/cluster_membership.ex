defmodule Steward.ClusterMembership do
  @moduledoc "Tracks BEAM node and process membership for status projection."
  use GenServer

  alias Steward.Types

  @pubsub Steward.PubSub
  @topic "cluster_membership:changed"

  @type state :: %{
          nodes: %{optional(Types.node_id()) => Types.node_status()},
          processes_by_node: %{optional(Types.node_id()) => MapSet.t(Types.process_id())}
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec snapshot() :: %{nodes: map(), processes_by_node: map()}
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @spec attach_process(node(), Types.process_id()) :: :ok
  def attach_process(node_name, process_id)
      when is_atom(node_name) and is_binary(process_id) and process_id != "" do
    GenServer.cast(__MODULE__, {:attach_process, node_name, process_id})
  end

  @spec detach_process(node(), Types.process_id()) :: :ok
  def detach_process(node_name, process_id)
      when is_atom(node_name) and is_binary(process_id) and process_id != "" do
    GenServer.cast(__MODULE__, {:detach_process, node_name, process_id})
  end

  @impl true
  def init(:ok) do
    :ok = :net_kernel.monitor_nodes(true)

    nodes =
      [node() | Node.list()]
      |> Enum.uniq()
      |> Enum.reduce(%{}, fn node_name, acc -> Map.put(acc, node_name, :up) end)

    processes_by_node =
      Enum.reduce(Map.keys(nodes), %{}, fn node_name, acc ->
        Map.put(acc, node_name, MapSet.new())
      end)

    {:ok, %{nodes: nodes, processes_by_node: processes_by_node}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_from_state(state), state}
  end

  @impl true
  def handle_cast({:attach_process, node_name, process_id}, state) do
    next_state =
      state
      |> put_node_status(node_name, :up)
      |> ensure_node_process_set(node_name)
      |> update_in([:processes_by_node, node_name], &MapSet.put(&1, process_id))

    publish_change(next_state, {:attach_process, node_name, process_id})
    {:noreply, next_state}
  end

  def handle_cast({:detach_process, node_name, process_id}, state) do
    next_state =
      state
      |> ensure_node_process_set(node_name)
      |> update_in([:processes_by_node, node_name], &MapSet.delete(&1, process_id))

    publish_change(next_state, {:detach_process, node_name, process_id})
    {:noreply, next_state}
  end

  @impl true
  def handle_info({:nodeup, node_name}, state) do
    next_state =
      state
      |> put_node_status(node_name, :up)
      |> ensure_node_process_set(node_name)

    publish_change(next_state, {:nodeup, node_name})
    {:noreply, next_state}
  end

  @impl true
  def handle_info({:nodedown, node_name}, state) do
    next_state =
      state
      |> put_node_status(node_name, :down)
      |> ensure_node_process_set(node_name)

    publish_change(next_state, {:nodedown, node_name})
    {:noreply, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp put_node_status(state, node_name, status) do
    put_in(state, [:nodes, node_name], status)
  end

  defp ensure_node_process_set(state, node_name) do
    update_in(state.processes_by_node, fn processes_by_node ->
      Map.put_new(processes_by_node, node_name, MapSet.new())
    end)
  end

  defp snapshot_from_state(state) do
    %{
      nodes: state.nodes,
      processes_by_node: state.processes_by_node
    }
  end

  defp publish_change(state, reason) do
    snapshot = snapshot_from_state(state)

    if Process.whereis(Steward.StatusStore) do
      Steward.StatusStore.refresh_membership(snapshot)
    end

    Phoenix.PubSub.broadcast(@pubsub, @topic, %{
      event: :cluster_membership_changed,
      reason: reason,
      snapshot: snapshot
    })

    :ok
  end
end
