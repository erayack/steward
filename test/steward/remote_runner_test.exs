defmodule Steward.RemoteRunnerTest do
  use ExUnit.Case, async: false

  alias Steward.{RemoteRunner, Types}

  defmodule TestActions do
    @behaviour Steward.Actions

    @impl true
    def apply(_action, params) do
      counter = Map.get(params, :counter_name)

      if is_atom(counter) and Process.whereis(counter) do
        Agent.update(counter, fn calls -> [params | calls] end)
      end

      case Map.get(params, :process_id) do
        "mock_fail" -> {:error, :mock_failure}
        _ -> :ok
      end
    end
  end

  setup do
    counter_name = :"remote_runner_counter_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_link(fn -> [] end, name: counter_name)

    run_cfg = Application.get_env(:steward, :run, [])
    Application.put_env(:steward, :run, Keyword.put(run_cfg, :actions_module, TestActions))

    on_exit(fn ->
      Application.put_env(:steward, :run, run_cfg)
      if Process.whereis(counter_name), do: Agent.stop(counter_name)
    end)

    %{counter_name: counter_name}
  end

  test "apply_run/1 executes targets once and then returns already_applied", %{
    counter_name: counter_name
  } do
    run_id = "remote-run-#{System.unique_integer([:positive])}"

    run = %Types.Run{
      run_id: run_id,
      action: :panic_fail_open,
      targets: ["mock_agent"],
      params: %{counter_name: counter_name},
      desired_config_version: nil,
      status: :running,
      results: %{},
      started_at: DateTime.utc_now(),
      finished_at: nil
    }

    assert {:ok, %{"mock_agent" => :success}} = RemoteRunner.apply_run(run)
    assert {:ok, %{"mock_agent" => :already_applied}} = RemoteRunner.apply_run(run)

    calls = Agent.get(counter_name, & &1)
    assert length(calls) == 1
  end

  test "apply_run/1 returns per-target failures from action backend", %{
    counter_name: counter_name
  } do
    run = %Types.Run{
      run_id: "remote-run-fail-#{System.unique_integer([:positive])}",
      action: :panic_fail_open,
      targets: ["mock_fail"],
      params: %{counter_name: counter_name},
      desired_config_version: nil,
      status: :running,
      results: %{},
      started_at: DateTime.utc_now(),
      finished_at: nil
    }

    assert {:ok, %{"mock_fail" => {:error, :mock_failure}}} = RemoteRunner.apply_run(run)
  end
end
