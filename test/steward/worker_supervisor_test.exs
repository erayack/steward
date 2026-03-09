defmodule Steward.WorkerSupervisorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Steward.{ClusterMembership, WorkerSupervisor}

  # ---------------------------------------------------------------------------
  # valid_process_id?/1
  # ---------------------------------------------------------------------------

  describe "valid_process_id?/1" do
    test "non-empty string is valid" do
      assert WorkerSupervisor.valid_process_id?("abc")
    end

    test "empty string is invalid" do
      refute WorkerSupervisor.valid_process_id?("")
    end

    test "nil is invalid" do
      refute WorkerSupervisor.valid_process_id?(nil)
    end

    test "integer is invalid" do
      refute WorkerSupervisor.valid_process_id?(42)
    end
  end

  # ---------------------------------------------------------------------------
  # valid_args?/1
  # ---------------------------------------------------------------------------

  describe "valid_args?/1" do
    test "list of strings is valid" do
      assert WorkerSupervisor.valid_args?(["a", "b"])
    end

    test "empty list is valid" do
      assert WorkerSupervisor.valid_args?([])
    end

    test "list with integer is invalid" do
      refute WorkerSupervisor.valid_args?([1])
    end

    test "list with mixed types is invalid" do
      refute WorkerSupervisor.valid_args?(["a", 1])
    end

    test "non-list is invalid" do
      refute WorkerSupervisor.valid_args?("x")
    end
  end

  # ---------------------------------------------------------------------------
  # normalize_worker_spec/1
  # ---------------------------------------------------------------------------

  describe "normalize_worker_spec/1" do
    test "valid map with atom keys returns spec" do
      spec = %{process_id: "w1", binary_path: "/bin/echo", args: []}

      assert [%{process_id: "w1", binary_path: "/bin/echo", args: []}] =
               WorkerSupervisor.normalize_worker_spec(spec)
    end

    test "valid map with string keys returns spec" do
      spec = %{"process_id" => "w2", "binary_path" => "/bin/echo"}

      assert [%{process_id: "w2", binary_path: "/bin/echo", args: []}] =
               WorkerSupervisor.normalize_worker_spec(spec)
    end

    test "valid map with args passes them through" do
      spec = %{process_id: "w3", binary_path: "/bin/echo", args: ["--flag"]}

      assert [%{args: ["--flag"]}] = WorkerSupervisor.normalize_worker_spec(spec)
    end

    test "valid api worker with atom keys returns spec" do
      spec = %{process_id: "api_1", transport: :api, base_url: "http://127.0.0.1:5001"}

      assert [%{process_id: "api_1", transport: :api, base_url: "http://127.0.0.1:5001"}] =
               WorkerSupervisor.normalize_worker_spec(spec)
    end

    test "valid api worker with string keys returns spec" do
      spec = %{
        "process_id" => "api_2",
        "transport" => "api",
        "base_url" => "http://127.0.0.1:5002"
      }

      assert [%{process_id: "api_2", transport: :api, base_url: "http://127.0.0.1:5002"}] =
               WorkerSupervisor.normalize_worker_spec(spec)
    end

    test "missing process_id returns empty list" do
      log =
        capture_log(fn ->
          assert [] = WorkerSupervisor.normalize_worker_spec(%{binary_path: "/bin/echo"})
        end)

      assert log =~ "skipping invalid worker bootstrap entry"
    end

    test "empty process_id returns empty list" do
      log =
        capture_log(fn ->
          assert [] =
                   WorkerSupervisor.normalize_worker_spec(%{
                     process_id: "",
                     binary_path: "/bin/echo"
                   })
        end)

      assert log =~ "skipping invalid worker bootstrap entry"
    end

    test "missing binary_path returns empty list" do
      log =
        capture_log(fn ->
          assert [] = WorkerSupervisor.normalize_worker_spec(%{process_id: "w4"})
        end)

      assert log =~ "skipping invalid worker bootstrap entry"
    end

    test "invalid args returns empty list" do
      log =
        capture_log(fn ->
          assert [] =
                   WorkerSupervisor.normalize_worker_spec(%{
                     process_id: "w5",
                     binary_path: "/bin/echo",
                     args: [1]
                   })
        end)

      assert log =~ "skipping invalid worker bootstrap entry"
    end

    test "non-map returns empty list" do
      log =
        capture_log(fn ->
          assert [] = WorkerSupervisor.normalize_worker_spec("garbage")
        end)

      assert log =~ "skipping non-map worker bootstrap entry"
    end
  end

  # ---------------------------------------------------------------------------
  # bootstrap_specs/0
  # ---------------------------------------------------------------------------

  describe "bootstrap_specs/0" do
    setup do
      prev_workers = Application.get_env(:steward, :workers)

      on_exit(fn ->
        if prev_workers do
          Application.put_env(:steward, :workers, prev_workers)
        else
          Application.delete_env(:steward, :workers)
        end
      end)

      :ok
    end

    test "reads :workers config when present" do
      Application.put_env(:steward, :workers, [
        %{process_id: "a", binary_path: "/bin/echo", args: []},
        %{process_id: "b", binary_path: "/bin/cat", args: []}
      ])

      specs = WorkerSupervisor.bootstrap_specs()
      ids = Enum.map(specs, & &1.process_id)
      assert "a" in ids
      assert "b" in ids
    end

    test "deduplicates by process_id" do
      Application.put_env(:steward, :workers, [
        %{process_id: "dup", binary_path: "/bin/echo", args: []},
        %{process_id: "dup", binary_path: "/bin/cat", args: []}
      ])

      specs = WorkerSupervisor.bootstrap_specs()
      assert length(specs) == 1
      assert hd(specs).process_id == "dup"
    end

    test "returns empty when :workers is empty list" do
      Application.put_env(:steward, :workers, [])

      specs = WorkerSupervisor.bootstrap_specs()
      assert specs == []
    end

    test "returns empty when :workers is not set" do
      Application.delete_env(:steward, :workers)

      specs = WorkerSupervisor.bootstrap_specs()
      assert specs == []
    end

    test "skips invalid entries in :workers list" do
      Application.put_env(:steward, :workers, [
        %{process_id: "good", binary_path: "/bin/echo", args: []},
        "bad_entry",
        %{process_id: "", binary_path: "/bin/echo"}
      ])

      log =
        capture_log(fn ->
          specs = WorkerSupervisor.bootstrap_specs()
          assert length(specs) == 1
          assert hd(specs).process_id == "good"
        end)

      assert log =~ "skipping"
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: ensure_worker/3, terminate_worker/1, list_workers/0
  # ---------------------------------------------------------------------------

  describe "integration" do
    setup do
      registry_name = :"test_registry_#{System.unique_integer([:positive])}"
      ds_name = :"test_ds_#{System.unique_integer([:positive])}"
      ws_name = :"test_ws_#{System.unique_integer([:positive])}"

      {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)
      {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: ds_name)

      {:ok, ws_pid} =
        WorkerSupervisor.start_link(
          name: ws_name,
          registry: registry_name,
          dynamic_supervisor: ds_name,
          bootstrap?: false
        )

      on_exit(fn ->
        if Process.alive?(ws_pid) do
          try do
            GenServer.stop(ws_pid)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{ws: ws_name, registry: registry_name, ds: ds_name}
    end

    test "ensure_worker starts a worker process", %{ws: ws} do
      assert {:ok, pid} = GenServer.call(ws, {:ensure_worker, "itest_1", "/bin/cat", []})
      assert is_pid(pid)
      assert Process.alive?(pid)

      GenServer.call(ws, {:terminate_worker, "itest_1"})
    end

    test "ensure_worker is idempotent — same pid returned", %{ws: ws} do
      {:ok, pid1} = GenServer.call(ws, {:ensure_worker, "itest_idem", "/bin/cat", []})
      {:ok, pid2} = GenServer.call(ws, {:ensure_worker, "itest_idem", "/bin/cat", []})
      assert pid1 == pid2

      GenServer.call(ws, {:terminate_worker, "itest_idem"})
    end

    test "ensure_worker rejects empty process_id" do
      assert_raise FunctionClauseError, fn ->
        WorkerSupervisor.ensure_worker("", "/bin/cat", [])
      end
    end

    test "ensure_worker rejects non-binary process_id" do
      assert_raise FunctionClauseError, fn ->
        WorkerSupervisor.ensure_worker(123, "/bin/cat", [])
      end
    end

    test "ensure_worker validates binary_path inside GenServer", %{ws: ws} do
      assert {:error, :invalid_binary_path} =
               GenServer.call(ws, {:ensure_worker, "bad_path", "", []})
    end

    test "ensure_worker validates args inside GenServer", %{ws: ws} do
      assert {:error, :invalid_args} =
               GenServer.call(ws, {:ensure_worker, "bad_args", "/bin/cat", [1]})
    end

    test "upgrade_worker returns error when hot swap is disabled", %{ws: ws} do
      prev_hot_swap = Application.get_env(:steward, :hot_swap, [])
      Application.put_env(:steward, :hot_swap, Keyword.merge(prev_hot_swap, enabled: false))
      on_exit(fn -> Application.put_env(:steward, :hot_swap, prev_hot_swap) end)

      assert {:error, :hot_swap_disabled} =
               GenServer.call(ws, {:upgrade_worker, "itest_1", "/bin/cat", [], []})
    end

    test "upgrade_worker starts when hot swap is enabled", %{ws: ws} do
      prev_hot_swap = Application.get_env(:steward, :hot_swap, [])
      Application.put_env(:steward, :hot_swap, Keyword.merge(prev_hot_swap, enabled: true))
      on_exit(fn -> Application.put_env(:steward, :hot_swap, prev_hot_swap) end)

      assert {:ok, _pid} = GenServer.call(ws, {:ensure_worker, "itest_upgrade", "/bin/cat", []})
      assert :ok = GenServer.call(ws, {:upgrade_worker, "itest_upgrade", "/bin/cat", [], []})

      GenServer.call(ws, {:terminate_worker, "itest_upgrade"})
    end

    test "ensure/terminate updates cluster membership", %{ws: ws} do
      process_id = "itest_term_#{System.unique_integer([:positive])}"

      pre_snapshot = ClusterMembership.snapshot()
      pre_members = Map.get(pre_snapshot.processes_by_node, node(), MapSet.new())

      {:ok, pid} = GenServer.call(ws, {:ensure_worker, process_id, "/bin/cat", []})
      Process.sleep(20)
      assert MapSet.member?(ClusterMembership.snapshot().processes_by_node[node()], process_id)

      assert :ok = GenServer.call(ws, {:terminate_worker, process_id})
      Process.sleep(20)
      refute Process.alive?(pid)

      post_snapshot = ClusterMembership.snapshot()
      post_members = Map.get(post_snapshot.processes_by_node, node(), MapSet.new())
      refute MapSet.member?(post_members, process_id)
      assert MapSet.subset?(pre_members, post_members)
    end

    test "terminate_worker removes worker", %{ws: ws} do
      {:ok, pid} = GenServer.call(ws, {:ensure_worker, "itest_term", "/bin/cat", []})
      assert Process.alive?(pid)

      assert :ok = GenServer.call(ws, {:terminate_worker, "itest_term"})
      Process.sleep(20)
      refute Process.alive?(pid)
    end

    test "terminate_worker returns :ok for unknown process_id", %{ws: ws} do
      assert :ok = GenServer.call(ws, {:terminate_worker, "nonexistent"})
    end

    test "list_workers returns sorted refs", %{ws: ws} do
      {:ok, _} = GenServer.call(ws, {:ensure_worker, "z_worker", "/bin/cat", []})
      {:ok, _} = GenServer.call(ws, {:ensure_worker, "a_worker", "/bin/cat", []})

      refs = GenServer.call(ws, :list_workers)
      assert length(refs) == 2
      ids = Enum.map(refs, & &1.process_id)
      assert ids == ["a_worker", "z_worker"]

      for ref <- refs do
        assert Map.has_key?(ref, :process_id)
        assert Map.has_key?(ref, :pid)
        assert ref.transport == :port
        assert is_pid(ref.pid)
      end

      GenServer.call(ws, {:terminate_worker, "a_worker"})
      GenServer.call(ws, {:terminate_worker, "z_worker"})
    end

    test "list_workers is empty when no workers started", %{ws: ws} do
      assert [] = GenServer.call(ws, :list_workers)
    end

    test "bootstrap supports api workers without starting local ports", %{ws: ws} do
      prev_workers = Application.get_env(:steward, :workers)

      on_exit(fn ->
        if prev_workers do
          Application.put_env(:steward, :workers, prev_workers)
        else
          Application.delete_env(:steward, :workers)
        end
      end)

      process_id = "api_worker_#{System.unique_integer([:positive])}"

      Application.put_env(:steward, :workers, [
        %{process_id: process_id, transport: :api, base_url: "http://127.0.0.1:5051"}
      ])

      ws_pid = Process.whereis(ws)
      send(ws_pid, :bootstrap_workers)
      Process.sleep(50)

      refs = GenServer.call(ws, :list_workers)

      assert [%{process_id: ^process_id, pid: nil, transport: :api, base_url: base_url}] = refs
      assert base_url == "http://127.0.0.1:5051"
      assert_attached_in_membership(process_id)
    end

    test "list_workers excludes terminated workers", %{ws: ws} do
      {:ok, _} = GenServer.call(ws, {:ensure_worker, "temp", "/bin/cat", []})
      GenServer.call(ws, {:terminate_worker, "temp"})
      Process.sleep(20)

      assert [] = GenServer.call(ws, :list_workers)
    end
  end

  # ---------------------------------------------------------------------------
  # Bootstrap message integration
  # ---------------------------------------------------------------------------

  describe "bootstrap message" do
    setup do
      prev_workers = Application.get_env(:steward, :workers)

      on_exit(fn ->
        if prev_workers do
          Application.put_env(:steward, :workers, prev_workers)
        else
          Application.delete_env(:steward, :workers)
        end
      end)

      :ok
    end

    test "bootstrap_workers message starts configured workers" do
      Application.put_env(:steward, :workers, [
        %{process_id: "boot_a", binary_path: "/bin/cat", args: []},
        %{process_id: "boot_b", binary_path: "/bin/cat", args: []}
      ])

      registry_name = :"boot_reg_#{System.unique_integer([:positive])}"
      ds_name = :"boot_ds_#{System.unique_integer([:positive])}"
      ws_name = :"boot_ws_#{System.unique_integer([:positive])}"

      {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)
      {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: ds_name)

      {:ok, ws_pid} =
        WorkerSupervisor.start_link(
          name: ws_name,
          registry: registry_name,
          dynamic_supervisor: ds_name,
          bootstrap?: false
        )

      # Manually trigger bootstrap
      send(ws_pid, :bootstrap_workers)
      Process.sleep(100)

      refs = GenServer.call(ws_name, :list_workers)
      ids = Enum.map(refs, & &1.process_id) |> Enum.sort()
      assert ids == ["boot_a", "boot_b"]
      assert_attached_in_membership("boot_a")
      assert_attached_in_membership("boot_b")

      GenServer.stop(ws_pid)
    end

    test "bootstrap_workers logs error for non-existent binary" do
      Application.put_env(:steward, :workers, [
        %{process_id: "boot_bad", binary_path: "/nonexistent/binary", args: []}
      ])

      registry_name = :"boot_err_reg_#{System.unique_integer([:positive])}"
      ds_name = :"boot_err_ds_#{System.unique_integer([:positive])}"
      ws_name = :"boot_err_ws_#{System.unique_integer([:positive])}"

      {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)
      {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: ds_name)

      {:ok, ws_pid} =
        WorkerSupervisor.start_link(
          name: ws_name,
          registry: registry_name,
          dynamic_supervisor: ds_name,
          bootstrap?: false
        )

      log =
        capture_log(fn ->
          send(ws_pid, :bootstrap_workers)
          Process.sleep(100)
        end)

      assert log =~ "failed to bootstrap worker boot_bad"

      GenServer.stop(ws_pid)
    end
  end

  defp assert_attached_in_membership(process_id),
    do: assert_attached_in_membership(process_id, 30)

  defp assert_attached_in_membership(_process_id, 0),
    do: flunk("process was not attached in cluster membership")

  defp assert_attached_in_membership(process_id, attempts_left) do
    attached? =
      ClusterMembership.snapshot()
      |> Map.get(:processes_by_node, %{})
      |> Map.get(node(), MapSet.new())
      |> MapSet.member?(process_id)

    if attached? do
      :ok
    else
      Process.sleep(10)
      assert_attached_in_membership(process_id, attempts_left - 1)
    end
  end
end
