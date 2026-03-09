defmodule Steward.AutomationEngineTest do
  use ExUnit.Case, async: false

  alias Steward.SelfHealing.AutomationEngine

  describe "evaluate_snapshot/1" do
    test "returns trigger when vantage drop crosses threshold" do
      input = %{
        current_vantage_pct: 60.0,
        previous_vantage_pct: 90.0,
        vantage_drop_threshold_pct: 25.0,
        default_action: :panic_fail_open,
        targets: ["proc-b", "proc-a"],
        automation_id: :vantage_drop,
        cluster_id: "cluster-1"
      }

      assert {:trigger, decision} = AutomationEngine.evaluate_snapshot(input)
      assert decision.automation_id == :vantage_drop
      assert decision.action == :panic_fail_open
      assert decision.targets == ["proc-a", "proc-b"]
      assert decision.trigger_source == :metric
      assert_in_delta decision.trigger_reason.drop_pct, 33.33, 0.01
      assert decision.trigger_reason.cluster_id == "cluster-1"
      assert is_binary(decision.fingerprint)
    end

    test "returns noop when threshold is not crossed" do
      input = %{
        current_vantage_pct: 70.0,
        previous_vantage_pct: 80.0,
        vantage_drop_threshold_pct: 25.0,
        targets: ["proc-a"]
      }

      assert :noop = AutomationEngine.evaluate_snapshot(input)
    end

    test "returns noop when previous vantage is missing" do
      input = %{
        current_vantage_pct: 70.0,
        vantage_drop_threshold_pct: 25.0,
        targets: ["proc-a"]
      }

      assert :noop = AutomationEngine.evaluate_snapshot(input)
    end
  end

  describe "trigger_run/3" do
    test "creates and executes a metric-triggered run" do
      target = "missing-target-#{System.unique_integer([:positive])}"

      assert {:ok, run} =
               AutomationEngine.trigger_run(:panic_fail_open, [target], %{
                 automation_id: :vantage_drop,
                 trigger_source: :metric,
                 trigger_reason: %{signal: :vantage_drop_pct, drop_pct: 30.0}
               })

      assert run.status == :done
      assert run.trigger_source == :metric
      assert run.trigger_reason == %{signal: :vantage_drop_pct, drop_pct: 30.0}
      assert run.results[target] == :not_found
      assert run.params.automation_id == :vantage_drop
    end

    test "rejects invalid action" do
      assert {:error, :invalid_action} =
               AutomationEngine.trigger_run(:unknown_action, ["proc-a"], %{})
    end
  end
end
