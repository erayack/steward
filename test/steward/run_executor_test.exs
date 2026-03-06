defmodule Steward.RunExecutorTest do
  use ExUnit.Case, async: false

  alias Steward.{ClusterMembership, RunExecutor, RunRegistry}

  defmodule TestActions do
    @behaviour Steward.Actions

    @impl true
    def apply(_action, params) do
      counter = Map.get(params, :counter_name)

      if is_atom(counter) and Process.whereis(counter) do
        Agent.update(counter, fn calls -> [params | calls] end)
      end

      :ok
    end
  end

  setup do
    counter_name = :"run_executor_counter_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_link(fn -> [] end, name: counter_name)

    run_cfg = Application.get_env(:steward, :run, [])
    Application.put_env(:steward, :run, Keyword.put(run_cfg, :actions_module, TestActions))

    on_exit(fn ->
      ClusterMembership.detach_process(node(), "executor_target")
      Application.put_env(:steward, :run, run_cfg)
      if Process.whereis(counter_name), do: Agent.stop(counter_name)
    end)

    :ok = ClusterMembership.attach_process(node(), "executor_target")
    wait_until_attached("executor_target")

    %{counter_name: counter_name}
  end

  test "execute/1 fans out and keeps unresolved targets explicit", %{counter_name: counter_name} do
    run_id = "executor-run-#{System.unique_integer([:positive])}"

    assert {:ok, run} =
             RunRegistry.create_run(%{
               run_id: run_id,
               action: :panic_fail_open,
               targets: ["executor_target", "missing_target"],
               params: %{counter_name: counter_name}
             })

    assert {:ok, executed_run} = RunExecutor.execute(run)
    assert executed_run.status == :done
    assert executed_run.results["executor_target"] == :success
    assert executed_run.results["missing_target"] == :not_found

    snapshot = RunRegistry.snapshot()
    assert snapshot.completed_runs[run_id].results["executor_target"] == :success
    assert snapshot.completed_runs[run_id].results["missing_target"] == :not_found

    calls = Agent.get(counter_name, & &1)
    assert Enum.any?(calls, fn params -> Map.get(params, :process_id) == "executor_target" end)
  end

  defp wait_until_attached(process_id), do: wait_until_attached(process_id, 20)

  defp wait_until_attached(_process_id, 0),
    do: flunk("process was not attached in cluster membership")

  defp wait_until_attached(process_id, attempts_left) do
    attached? =
      ClusterMembership.snapshot()
      |> Map.get(:processes_by_node, %{})
      |> Map.get(node(), MapSet.new())
      |> MapSet.member?(process_id)

    if attached? do
      :ok
    else
      Process.sleep(10)
      wait_until_attached(process_id, attempts_left - 1)
    end
  end
end
