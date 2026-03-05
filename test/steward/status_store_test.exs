defmodule Steward.StatusStoreTest do
  use ExUnit.Case, async: false

  alias Steward.StatusStore

  setup do
    pid = Process.whereis(StatusStore) || start_supervised!(StatusStore)
    :sys.replace_state(StatusStore, fn _ -> %{processes: %{}, control_events: %{}} end)

    {:ok, pid: pid}
  end

  # ---------------------------------------------------------------------------
  # upsert_process_snapshot/2 + get_process_snapshot/1
  # ---------------------------------------------------------------------------

  describe "upsert_process_snapshot/2 + get_process_snapshot/1" do
    test "round-trip: store and retrieve snapshot" do
      snapshot = %{status: :up, pid: "abc123"}
      :ok = StatusStore.upsert_process_snapshot("proc_1", snapshot)

      assert StatusStore.get_process_snapshot("proc_1") == snapshot
    end

    test "upsert overwrites previous snapshot" do
      :ok = StatusStore.upsert_process_snapshot("proc_1", %{v: 1})
      :ok = StatusStore.upsert_process_snapshot("proc_1", %{v: 2})

      assert StatusStore.get_process_snapshot("proc_1") == %{v: 2}
    end
  end

  # ---------------------------------------------------------------------------
  # list_process_snapshots/0
  # ---------------------------------------------------------------------------

  describe "list_process_snapshots/0" do
    test "returns all stored snapshots" do
      :ok = StatusStore.upsert_process_snapshot("a", %{id: "a"})
      :ok = StatusStore.upsert_process_snapshot("b", %{id: "b"})

      snapshots = StatusStore.list_process_snapshots()
      assert length(snapshots) == 2
      assert %{id: "a"} in snapshots
      assert %{id: "b"} in snapshots
    end

    test "returns empty list when no snapshots stored" do
      assert StatusStore.list_process_snapshots() == []
    end
  end

  # ---------------------------------------------------------------------------
  # record_control_event/3 + list_control_events/1
  # ---------------------------------------------------------------------------

  describe "record_control_event/3 + list_control_events/1" do
    test "round-trip: store event, retrieve by process_id" do
      :ok = StatusStore.record_control_event("proc_1", :restart, %{reason: "crash"})

      events = StatusStore.list_control_events("proc_1")
      assert length(events) == 1

      [event] = events
      assert event.kind == :restart
      assert event.payload == %{reason: "crash"}
      assert is_integer(event.ts_ms)
    end

    test "events accumulate in order" do
      :ok = StatusStore.record_control_event("proc_1", :start)
      :ok = StatusStore.record_control_event("proc_1", :stop)

      events = StatusStore.list_control_events("proc_1")
      assert length(events) == 2
      assert Enum.map(events, & &1.kind) == [:start, :stop]
    end
  end

  # ---------------------------------------------------------------------------
  # Control events bounded to 100
  # ---------------------------------------------------------------------------

  describe "control events bounded to 100" do
    test "insert 105 events, list returns last 100" do
      for i <- 1..105 do
        :ok = StatusStore.record_control_event("bounded", :tick, %{seq: i})
      end

      events = StatusStore.list_control_events("bounded")
      assert length(events) == 100

      # Oldest retained event should be seq 6 (first 5 dropped)
      assert List.first(events).payload == %{seq: 6}
      assert List.last(events).payload == %{seq: 105}
    end
  end

  # ---------------------------------------------------------------------------
  # Missing process_id → nil / empty
  # ---------------------------------------------------------------------------

  describe "missing process_id" do
    test "get_process_snapshot returns nil" do
      assert StatusStore.get_process_snapshot("nope") == nil
    end

    test "list_control_events returns empty list" do
      assert StatusStore.list_control_events("nope") == []
    end
  end
end
