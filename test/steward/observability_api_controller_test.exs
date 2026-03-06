defmodule Steward.ObservabilityAPIControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Steward.WorkerSupervisor
  alias StewardWeb.Router

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

  test "POST /api/v1/runs without targets executes on bootstrapped workers" do
    counter_name = :"api_runs_counter_#{System.unique_integer([:positive])}"
    registry_name = :"api_boot_reg_#{System.unique_integer([:positive])}"
    ds_name = :"api_boot_ds_#{System.unique_integer([:positive])}"
    ws_name = :"api_boot_ws_#{System.unique_integer([:positive])}"
    worker_ids = ["api_boot_a", "api_boot_b"]

    {:ok, _pid} = Agent.start_link(fn -> [] end, name: counter_name)
    {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)
    {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: ds_name)

    prev_workers = Application.get_env(:steward, :workers)
    prev_run_cfg = Application.get_env(:steward, :run, [])

    Application.put_env(:steward, :workers, [
      %{process_id: "api_boot_a", binary_path: "/bin/cat", args: []},
      %{process_id: "api_boot_b", binary_path: "/bin/cat", args: []}
    ])

    Application.put_env(:steward, :run, Keyword.put(prev_run_cfg, :actions_module, TestActions))

    {:ok, ws_pid} =
      WorkerSupervisor.start_link(
        name: ws_name,
        registry: registry_name,
        dynamic_supervisor: ds_name,
        bootstrap?: false
      )

    on_exit(fn ->
      Application.put_env(:steward, :run, prev_run_cfg)

      if prev_workers do
        Application.put_env(:steward, :workers, prev_workers)
      else
        Application.delete_env(:steward, :workers)
      end

      if Process.whereis(counter_name), do: Agent.stop(counter_name)

      if Process.alive?(ws_pid) do
        try do
          GenServer.stop(ws_pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    send(ws_pid, :bootstrap_workers)
    Enum.each(worker_ids, &wait_until_attached/1)

    conn =
      conn(:post, "/api/v1/runs", %{
        "action" => "panic_fail_open",
        "params" => %{"counter_name" => counter_name}
      })
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 201

    payload = Jason.decode!(conn.resp_body)
    run = payload["run"]
    assert is_map(run)

    assert Enum.all?(worker_ids, &(&1 in run["targets"]))
    assert Enum.all?(worker_ids, fn id -> run["results"][id] == "success" end)

    calls = Agent.get(counter_name, & &1)
    called_process_ids = Enum.map(calls, &Map.get(&1, :process_id))
    assert Enum.all?(worker_ids, &(&1 in called_process_ids))
  end

  defp wait_until_attached(process_id), do: wait_until_attached(process_id, 30)

  defp wait_until_attached(_process_id, 0),
    do: flunk("process was not attached in cluster membership")

  defp wait_until_attached(process_id, attempts_left) do
    attached? =
      Steward.ClusterMembership.snapshot()
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
