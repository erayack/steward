defmodule Steward.ClusterMembership do
  @moduledoc "Tracks BEAM node membership for status projection."
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    :ok = :net_kernel.monitor_nodes(true)
    {:ok, MapSet.new([node() | Node.list()])}
  end

  @impl true
  def handle_info({:nodeup, node_name}, nodes) do
    {:noreply, MapSet.put(nodes, node_name)}
  end

  @impl true
  def handle_info({:nodedown, node_name}, nodes) do
    {:noreply, MapSet.delete(nodes, node_name)}
  end
end
