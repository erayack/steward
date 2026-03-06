defmodule Steward.RunTest do
  use ExUnit.Case, async: true

  alias Steward.Run

  describe "new/1" do
    test "builds a pending run with defaults" do
      attrs = %{run_id: "run-1", action: :restart, targets: ["mock_agent"]}
      assert {:ok, run} = Run.new(attrs)

      assert run.run_id == "run-1"
      assert run.action == :restart
      assert run.targets == ["mock_agent"]
      assert run.status == :pending
      assert run.params == %{}
      assert run.results == %{}
      assert run.started_at == nil
      assert run.finished_at == nil
    end

    test "rejects invalid attributes" do
      assert {:error, {:invalid_field, :run_id}} =
               Run.new(%{action: :restart, targets: ["mock_agent"]})

      assert {:error, {:invalid_field, :action}} =
               Run.new(%{run_id: "run-1", action: "restart", targets: ["mock_agent"]})

      assert {:error, {:invalid_field, :targets}} =
               Run.new(%{run_id: "run-1", action: :restart, targets: []})
    end
  end

  describe "lifecycle transitions" do
    test "supports pending -> running -> done only" do
      {:ok, run} = Run.new(%{run_id: "run-2", action: :restart, targets: ["mock_agent"]})
      assert {:ok, running} = Run.mark_running(run)
      assert running.status == :running
      assert %DateTime{} = running.started_at

      assert {:ok, done} = Run.complete(running, %{"mock_agent" => :success})
      assert done.status == :done
      assert done.results == %{"mock_agent" => :success}
      assert %DateTime{} = done.finished_at
    end

    test "rejects invalid transitions" do
      {:ok, run} = Run.new(%{run_id: "run-3", action: :restart, targets: ["mock_agent"]})

      assert {:error, :invalid_transition} = Run.complete(run, %{})
      assert {:ok, running} = Run.mark_running(run)
      assert {:error, :invalid_transition} = Run.mark_running(running)
      assert {:ok, done} = Run.complete(running, %{})
      assert {:error, :invalid_transition} = Run.mark_running(done)
    end
  end
end
