defmodule Steward.RunRegistryTest do
  use ExUnit.Case, async: true

  alias Steward.RunRegistry

  setup do
    name = :"run_registry_test_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      RunRegistry.start_link(
        name: name,
        idempotency_max_ids_per_node: 2,
        completed_runs_max: 2
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{registry: name}
  end

  describe "create_run/2 + mark_running/2 + complete_run/3" do
    test "stores active and completed runs with bounded history", %{registry: registry} do
      assert {:ok, run1} =
               RunRegistry.create_run(registry, %{
                 run_id: "run-1",
                 action: :restart,
                 targets: ["mock_agent"]
               })

      assert run1.status == :pending
      assert :ok = RunRegistry.mark_running(registry, "run-1")
      assert :ok = RunRegistry.complete_run(registry, "run-1", %{"mock_agent" => :success})

      snapshot = RunRegistry.snapshot(registry)
      assert map_size(snapshot.active_runs) == 0
      assert map_size(snapshot.completed_runs) == 1
      assert snapshot.completed_runs["run-1"].status == :done
      assert snapshot.completed_runs["run-1"].results == %{"mock_agent" => :success}
    end

    test "rejects duplicate run ids across active and completed", %{registry: registry} do
      assert {:ok, _} =
               RunRegistry.create_run(registry, %{
                 run_id: "dup-run",
                 action: :restart,
                 targets: ["mock_agent"]
               })

      assert {:error, :duplicate_run_id} =
               RunRegistry.create_run(registry, %{
                 run_id: "dup-run",
                 action: :restart,
                 targets: ["mock_agent"]
               })

      assert :ok = RunRegistry.mark_running(registry, "dup-run")
      assert :ok = RunRegistry.complete_run(registry, "dup-run", %{})

      assert {:error, :duplicate_run_id} =
               RunRegistry.create_run(registry, %{
                 run_id: "dup-run",
                 action: :restart,
                 targets: ["mock_agent"]
               })
    end

    test "drops oldest completed runs when max is exceeded", %{registry: registry} do
      for run_id <- ["run-1", "run-2", "run-3"] do
        assert {:ok, _} =
                 RunRegistry.create_run(registry, %{
                   run_id: run_id,
                   action: :restart,
                   targets: ["mock_agent"]
                 })

        assert :ok = RunRegistry.mark_running(registry, run_id)
        assert :ok = RunRegistry.complete_run(registry, run_id, %{})
      end

      snapshot = RunRegistry.snapshot(registry)
      assert snapshot.completed_runs |> Map.keys() |> Enum.sort() == ["run-2", "run-3"]
    end
  end

  describe "apply_once/3" do
    test "returns :applied once per node/run pair", %{registry: registry} do
      assert :applied = RunRegistry.apply_once(registry, node(), "run-42")
      assert :already_applied = RunRegistry.apply_once(registry, node(), "run-42")

      other = :"other@127.0.0.1"
      assert :applied = RunRegistry.apply_once(registry, other, "run-42")
    end

    test "keeps node idempotency history bounded", %{registry: registry} do
      assert :applied = RunRegistry.apply_once(registry, node(), "run-1")
      assert :applied = RunRegistry.apply_once(registry, node(), "run-2")
      assert :applied = RunRegistry.apply_once(registry, node(), "run-3")

      snapshot = RunRegistry.snapshot(registry)
      ids = snapshot.applied_run_ids[node()]

      assert MapSet.size(ids) == 2
      assert MapSet.member?(ids, "run-2")
      assert MapSet.member?(ids, "run-3")
      refute MapSet.member?(ids, "run-1")
    end
  end
end
