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

  test "state_payload includes metric-derived process fields and automation cards" do
    now = DateTime.utc_now()
    prev_self_healing = Application.get_env(:steward, :self_healing, [])

    Application.put_env(
      :steward,
      :self_healing,
      Keyword.merge(prev_self_healing, cooldown_ms: 60_000)
    )

    on_exit(fn -> Application.put_env(:steward, :self_healing, prev_self_healing) end)

    :sys.replace_state(StatusStore, fn state ->
      Map.merge(state, %{
        processes: %{
          "proc_1" => %{
            process_id: "proc_1",
            status: :up,
            last_heartbeat_at: now,
            restart_count: 1,
            quarantined_until_ms: nil,
            metrics: %{"vantage_pct" => 92.1, "cpu" => 0.62, "error_rate" => 0.03},
            metric_recent: %{"vantage_pct" => [94.0, 93.0, 92.1]},
            metrics_updated_at: now
          }
        },
        metric_baselines: %{"vantage_pct" => %{avg: 92.1, min: 92.1, max: 92.1, count: 1}},
        audit_events: [
          %{
            entity: :automation,
            event: :automation_triggered,
            ts_ms: System.system_time(:millisecond),
            trigger_reason: %{signal: :vantage_drop_pct}
          }
        ]
      })
    end)

    payload = Presenter.state_payload()
    [proc] = payload.processes
    [card] = payload.automation_cards

    assert proc.vantage_pct == 92.1
    assert proc.cpu == 0.62
    assert proc.error_rate == 0.03
    assert proc.metric_recent["vantage_pct"] == [94.0, 93.0, 92.1]
    assert is_binary(proc.metrics_updated_at)

    assert payload.metric_baselines["vantage_pct"].avg == 92.1
    assert card.id == "self_healing"
    assert card.status == "cooldown"
    assert card.cooldown_remaining_ms > 0
    assert card.last_trigger_reason == %{signal: :vantage_drop_pct}
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
