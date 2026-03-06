defmodule StewardWeb.PresenterTest do
  use ExUnit.Case, async: false

  alias Steward.{ClusterMembership, StatusStore}
  alias StewardWeb.Presenter

  defmodule TestActions do
    @behaviour Steward.Actions

    @impl true
    def apply(_action, params) do
      counter = Map.get(params, :counter_name) || Map.get(params, "counter_name")

      if is_atom(counter) and Process.whereis(counter) do
        Agent.update(counter, fn calls -> [params | calls] end)
      end

      :ok
    end
  end

  test "trigger_run_payload without explicit targets uses cluster membership targets" do
    process_id = "presenter_member_#{System.unique_integer([:positive])}"
    counter_name = :"presenter_counter_#{System.unique_integer([:positive])}"

    {:ok, _pid} = Agent.start_link(fn -> [] end, name: counter_name)

    run_cfg = Application.get_env(:steward, :run, [])
    Application.put_env(:steward, :run, Keyword.put(run_cfg, :actions_module, TestActions))

    :sys.replace_state(StatusStore, fn state ->
      %{state | processes: %{"stale_only" => %{process_id: "stale_only"}}}
    end)

    :ok = ClusterMembership.attach_process(node(), process_id)
    wait_until_attached(process_id)

    on_exit(fn ->
      ClusterMembership.detach_process(node(), process_id)
      Application.put_env(:steward, :run, run_cfg)
      if Process.whereis(counter_name), do: Agent.stop(counter_name)
    end)

    assert {:ok, %{run: run}} =
             Presenter.trigger_run_payload(%{
               "action" => "panic_fail_open",
               "params" => %{"counter_name" => counter_name}
             })

    assert process_id in run.targets
    assert run.results[process_id] == :success
    refute Map.has_key?(run.results, "stale_only")

    calls = Agent.get(counter_name, & &1)
    assert Enum.any?(calls, fn params -> Map.get(params, :process_id) == process_id end)
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
