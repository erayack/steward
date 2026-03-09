defmodule Steward.StatusStoreTest do
  use ExUnit.Case, async: false

  alias Steward.StatusStore

  setup do
    pid = Process.whereis(StatusStore) || start_supervised!(StatusStore)

    :sys.replace_state(StatusStore, fn _ ->
      %{
        processes: %{},
        control_events: %{},
        membership: %{nodes: %{}, processes_by_node: %{}},
        runs: %{active_runs: %{}, completed_runs: %{}, counts: %{}},
        metric_baselines: %{},
        audit_events: [],
        malformed_line_counts: %{},
        audit_seq: 0,
        updated_at_ms: System.monotonic_time(:millisecond)
      }
    end)

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

    test "maintains metric baselines from process snapshots" do
      :ok =
        StatusStore.upsert_process_snapshot("proc_1", %{
          metrics: %{"cpu" => 20, "vantage_pct" => 90.0}
        })

      :ok =
        StatusStore.upsert_process_snapshot("proc_2", %{
          metrics: %{"cpu" => 40, "vantage_pct" => 80.0}
        })

      snapshot = StatusStore.snapshot()

      assert snapshot.metric_baselines["cpu"] == %{avg: 30.0, min: 20.0, max: 40.0, count: 2}

      assert snapshot.metric_baselines["vantage_pct"] == %{
               avg: 85.0,
               min: 80.0,
               max: 90.0,
               count: 2
             }
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

  describe "append_event/1 + recent_events/1" do
    test "stores events in reverse-chronological access order" do
      assert :ok = StatusStore.append_event(%{event: :first, payload: %{x: 1}})
      assert :ok = StatusStore.append_event(%{event: :second, payload: %{x: 2}})

      events = StatusStore.recent_events(2)
      assert length(events) == 2
      assert Enum.map(events, & &1.event) == [:second, :first]
      assert Enum.all?(events, &is_integer(&1.event_id))
      assert Enum.all?(events, &is_integer(&1.ts_ms))
    end

    test "increments malformed protocol counters per process" do
      assert :ok =
               StatusStore.append_event(%{event: :protocol_malformed_line, process_id: "proc_1"})

      assert :ok =
               StatusStore.append_event(%{event: :protocol_malformed_line, process_id: "proc_1"})

      assert :ok =
               StatusStore.append_event(%{event: :protocol_malformed_line, process_id: "proc_2"})

      snapshot = StatusStore.snapshot()
      assert snapshot.malformed_line_counts["proc_1"] == 2
      assert snapshot.malformed_line_counts["proc_2"] == 1
    end

    test "snapshot includes self-healing trigger fields" do
      prev_self_healing = Application.get_env(:steward, :self_healing, [])

      Application.put_env(
        :steward,
        :self_healing,
        Keyword.merge(prev_self_healing, cooldown_ms: 30_000)
      )

      on_exit(fn -> Application.put_env(:steward, :self_healing, prev_self_healing) end)

      assert :ok =
               StatusStore.append_event(%{
                 entity: :automation,
                 event: :automation_triggered,
                 trigger_reason: %{signal: :vantage_drop_pct, drop_pct: 32.1}
               })

      snapshot = StatusStore.snapshot()

      assert is_integer(snapshot.self_healing.last_trigger_at_ms)

      assert snapshot.self_healing.last_trigger_reason == %{
               signal: :vantage_drop_pct,
               drop_pct: 32.1
             }

      assert is_integer(snapshot.self_healing.cooldown_remaining_ms)
      assert snapshot.self_healing.cooldown_remaining_ms >= 0
    end
  end
end
