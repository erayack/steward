defmodule Steward.ClusterMembershipTest do
  use ExUnit.Case, async: false

  alias Steward.ClusterMembership

  @topic "cluster_membership:changed"

  setup do
    pid = Process.whereis(ClusterMembership) || start_supervised!(ClusterMembership)
    Phoenix.PubSub.subscribe(Steward.PubSub, @topic)
    %{pid: pid}
  end

  describe "snapshot/0" do
    test "returns nodes and processes_by_node maps with local node present" do
      snapshot = ClusterMembership.snapshot()

      assert is_map(snapshot.nodes)
      assert is_map(snapshot.processes_by_node)
      assert Map.get(snapshot.nodes, node()) in [:up, :down]
      assert match?(%MapSet{}, Map.get(snapshot.processes_by_node, node(), MapSet.new()))
    end
  end

  describe "attach_process/2 and detach_process/2" do
    test "adds and removes process ids for node" do
      process_id = "cm_test_#{System.unique_integer([:positive])}"

      :ok = ClusterMembership.attach_process(node(), process_id)

      assert_receive %{
                       event: :cluster_membership_changed,
                       reason: {:attach_process, _, ^process_id}
                     },
                     200

      snapshot_after_attach = ClusterMembership.snapshot()
      assert snapshot_after_attach.nodes[node()] == :up
      assert MapSet.member?(snapshot_after_attach.processes_by_node[node()], process_id)

      :ok = ClusterMembership.detach_process(node(), process_id)

      assert_receive %{
                       event: :cluster_membership_changed,
                       reason: {:detach_process, _, ^process_id}
                     },
                     200

      snapshot_after_detach = ClusterMembership.snapshot()
      refute MapSet.member?(snapshot_after_detach.processes_by_node[node()], process_id)
    end
  end

  describe "node events" do
    test "marks node up/down and publishes changes", %{pid: pid} do
      fake_node = String.to_atom("cluster_test_#{System.unique_integer([:positive])}@localhost")

      send(pid, {:nodeup, fake_node})
      assert_receive %{event: :cluster_membership_changed, reason: {:nodeup, ^fake_node}}, 200

      snapshot_after_up = ClusterMembership.snapshot()
      assert snapshot_after_up.nodes[fake_node] == :up
      assert match?(%MapSet{}, snapshot_after_up.processes_by_node[fake_node])

      send(pid, {:nodedown, fake_node})
      assert_receive %{event: :cluster_membership_changed, reason: {:nodedown, ^fake_node}}, 200

      snapshot_after_down = ClusterMembership.snapshot()
      assert snapshot_after_down.nodes[fake_node] == :down
    end
  end
end
