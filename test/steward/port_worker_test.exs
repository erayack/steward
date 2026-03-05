defmodule Steward.PortWorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Steward.PortWorker

  # ---------------------------------------------------------------------------
  # parse_envelope/1
  # ---------------------------------------------------------------------------

  describe "parse_envelope/1" do
    test "parses valid heartbeat envelope" do
      line =
        Jason.encode!(%{
          "kind" => "heartbeat",
          "ts" => "2025-01-15T10:00:00Z",
          "fields" => %{"seq" => 1}
        })

      assert {:ok, envelope} = PortWorker.parse_envelope(line)
      assert envelope.kind == :heartbeat
      assert %DateTime{} = envelope.ts
      assert envelope.fields == %{"seq" => 1}
    end

    test "parses valid metric envelope" do
      line = Jason.encode!(%{"kind" => "metric", "fields" => %{"cpu" => 42.5}})

      assert {:ok, envelope} = PortWorker.parse_envelope(line)
      assert envelope.kind == :metric
      assert envelope.ts == nil
      assert envelope.fields == %{"cpu" => 42.5}
    end

    test "parses valid event envelope" do
      line = Jason.encode!(%{"kind" => "event", "fields" => %{}})
      assert {:ok, %{kind: :event}} = PortWorker.parse_envelope(line)
    end

    test "parses valid error envelope" do
      line = Jason.encode!(%{"kind" => "error", "fields" => %{"msg" => "boom"}})
      assert {:ok, %{kind: :error, fields: %{"msg" => "boom"}}} = PortWorker.parse_envelope(line)
    end

    test "unknown kind normalizes to :event" do
      line = Jason.encode!(%{"kind" => "foobar", "fields" => %{}})
      assert {:ok, %{kind: :event}} = PortWorker.parse_envelope(line)
    end

    test "missing kind normalizes to :event" do
      line = Jason.encode!(%{"fields" => %{}})
      assert {:ok, %{kind: :event}} = PortWorker.parse_envelope(line)
    end

    test "missing fields normalizes to empty map" do
      line = Jason.encode!(%{"kind" => "heartbeat"})
      assert {:ok, %{fields: %{}}} = PortWorker.parse_envelope(line)
    end

    test "returns :malformed for non-JSON" do
      assert :malformed = PortWorker.parse_envelope("not json at all")
    end

    test "returns :malformed for JSON array" do
      assert :malformed = PortWorker.parse_envelope("[1,2,3]")
    end

    test "returns :malformed for JSON scalar" do
      assert :malformed = PortWorker.parse_envelope("42")
    end

    test "null ts parses as nil" do
      line = Jason.encode!(%{"kind" => "event", "ts" => nil, "fields" => %{}})
      assert {:ok, %{ts: nil}} = PortWorker.parse_envelope(line)
    end

    test "invalid ts string parses as nil" do
      line = Jason.encode!(%{"kind" => "event", "ts" => "not-a-date", "fields" => %{}})
      assert {:ok, %{ts: nil}} = PortWorker.parse_envelope(line)
    end

    test "numeric ts parses as nil" do
      line = Jason.encode!(%{"kind" => "event", "ts" => 12_345, "fields" => %{}})
      assert {:ok, %{ts: nil}} = PortWorker.parse_envelope(line)
    end

    test "valid ISO8601 ts with offset" do
      line =
        Jason.encode!(%{"kind" => "event", "ts" => "2025-06-01T12:30:00+02:00", "fields" => %{}})

      assert {:ok, %{ts: %DateTime{}}} = PortWorker.parse_envelope(line)
    end
  end

  # ---------------------------------------------------------------------------
  # normalize_kind/1
  # ---------------------------------------------------------------------------

  describe "normalize_kind/1" do
    test "passes through known atoms" do
      for kind <- [:heartbeat, :metric, :event, :error] do
        assert PortWorker.normalize_kind(kind) == kind
      end
    end

    test "converts known binary strings to atoms" do
      assert PortWorker.normalize_kind("heartbeat") == :heartbeat
      assert PortWorker.normalize_kind("metric") == :metric
      assert PortWorker.normalize_kind("event") == :event
      assert PortWorker.normalize_kind("error") == :error
    end

    test "unknown string defaults to :event" do
      assert PortWorker.normalize_kind("unknown") == :event
      assert PortWorker.normalize_kind("") == :event
    end

    test "non-string non-atom defaults to :event" do
      assert PortWorker.normalize_kind(42) == :event
      assert PortWorker.normalize_kind(nil) == :event
      assert PortWorker.normalize_kind([]) == :event
    end
  end

  # ---------------------------------------------------------------------------
  # parse_ts/1
  # ---------------------------------------------------------------------------

  describe "parse_ts/1" do
    test "nil returns nil" do
      assert PortWorker.parse_ts(nil) == nil
    end

    test "valid ISO8601 returns DateTime" do
      assert %DateTime{year: 2025, month: 1, day: 15} =
               PortWorker.parse_ts("2025-01-15T10:00:00Z")
    end

    test "valid ISO8601 with offset returns DateTime" do
      assert %DateTime{} = PortWorker.parse_ts("2025-06-01T12:30:00+02:00")
    end

    test "invalid date string returns nil" do
      assert PortWorker.parse_ts("not-a-date") == nil
    end

    test "non-binary returns nil" do
      assert PortWorker.parse_ts(12_345) == nil
      assert PortWorker.parse_ts(%{}) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # normalize_fields/1
  # ---------------------------------------------------------------------------

  describe "normalize_fields/1" do
    test "returns map as-is" do
      assert PortWorker.normalize_fields(%{"a" => 1}) == %{"a" => 1}
    end

    test "non-map returns empty map" do
      assert PortWorker.normalize_fields(nil) == %{}
      assert PortWorker.normalize_fields("string") == %{}
      assert PortWorker.normalize_fields([1, 2]) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # encode_command_payload/1
  # ---------------------------------------------------------------------------

  describe "encode_command_payload/1" do
    test "wraps bare map in command envelope" do
      payload = PortWorker.encode_command_payload(%{"foo" => "bar"})
      assert String.ends_with?(payload, "\n")

      decoded = Jason.decode!(String.trim(payload))
      assert decoded["kind"] == "command"
      assert decoded["fields"] == %{"foo" => "bar"}
    end

    test "passes through map with string kind key" do
      input = %{"kind" => "custom", "data" => 1}
      payload = PortWorker.encode_command_payload(input)
      decoded = Jason.decode!(String.trim(payload))

      assert decoded["kind"] == "custom"
      assert decoded["data"] == 1
    end

    test "passes through map with atom kind key" do
      input = %{kind: "restart", target: "agent_1"}
      payload = PortWorker.encode_command_payload(input)
      decoded = Jason.decode!(String.trim(payload))

      assert decoded["kind"] == "restart"
    end

    test "payload is newline-terminated" do
      payload = PortWorker.encode_command_payload(%{"x" => 1})
      assert String.ends_with?(payload, "\n")
      refute String.ends_with?(payload, "\n\n")
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: GenServer lifecycle with real binary
  # ---------------------------------------------------------------------------

  describe "GenServer integration" do
    test "starts with /bin/cat and returns :up snapshot" do
      {:ok, pid} =
        PortWorker.start_link(
          process_id: "test_cat",
          binary_path: "/bin/cat",
          args: []
        )

      snapshot = PortWorker.snapshot(pid)
      assert snapshot.process_id == "test_cat"
      assert snapshot.status == :up
      assert snapshot.restart_count == 0
      assert snapshot.crash_timestamps_ms == []

      GenServer.stop(pid)
    end

    test "snapshot includes expected keys" do
      {:ok, pid} =
        PortWorker.start_link(
          process_id: "test_keys",
          binary_path: "/bin/cat",
          args: []
        )

      snapshot = PortWorker.snapshot(pid)

      expected_keys =
        ~w(process_id binary_path args status last_heartbeat_at last_event restart_count crash_timestamps_ms quarantined_until_ms)a

      for key <- expected_keys do
        assert Map.has_key?(snapshot, key), "missing key: #{key}"
      end

      GenServer.stop(pid)
    end

    test "init fails with non-existent binary" do
      Process.flag(:trap_exit, true)

      {result, log} =
        capture_log(fn ->
          result =
            PortWorker.start_link(
              process_id: "bad_binary",
              binary_path: "/nonexistent/path/binary",
              args: []
            )

          send(self(), {:start_result, result})
        end)
        |> then(fn log ->
          receive do
            {:start_result, result} -> {result, log}
          after
            100 -> flunk("missing start_link result")
          end
        end)

      assert {:error, {:port_open_failed, _reason}} = result
      assert log =~ "failed to start process bad_binary"
    end

    test "heartbeat line updates last_heartbeat_at" do
      {:ok, pid} =
        PortWorker.start_link(
          process_id: "test_heartbeat",
          binary_path: "/bin/cat",
          args: []
        )

      state = :sys.get_state(pid)

      line =
        Jason.encode!(%{"kind" => "heartbeat", "ts" => "2025-01-15T10:00:00Z", "fields" => %{}})

      send(pid, {state.port, {:data, {:eol, line}}})
      Process.sleep(20)

      snapshot = PortWorker.snapshot(pid)
      assert %DateTime{} = snapshot.last_heartbeat_at

      GenServer.stop(pid)
    end

    test "clean port exit restarts without incrementing crash counters" do
      {:ok, pid} =
        PortWorker.start_link(
          process_id: "test_clean_exit",
          binary_path: "/bin/cat",
          args: []
        )

      old_state = :sys.get_state(pid)
      Port.close(old_state.port)

      Process.sleep(50)

      snapshot = PortWorker.snapshot(pid)
      assert snapshot.status == :up
      assert snapshot.restart_count == 0
      assert snapshot.crash_timestamps_ms == []

      GenServer.stop(pid)
    end

    test "send_command dispatches to running port" do
      {:ok, pid} =
        PortWorker.start_link(
          process_id: "test_cmd",
          binary_path: "/bin/cat",
          args: []
        )

      assert :ok = PortWorker.send_command(pid, %{"action" => "ping"})
      GenServer.stop(pid)
    end

    test "JSONL line is parsed and updates last_event" do
      {:ok, pid} =
        PortWorker.start_link(
          process_id: "test_jsonl",
          binary_path: "/bin/cat",
          args: []
        )

      # Send a valid JSONL line through the port (cat echoes it back)
      line =
        Jason.encode!(%{"kind" => "heartbeat", "ts" => "2025-01-15T10:00:00Z", "fields" => %{}})

      :ok = PortWorker.send_command(pid, %{"echo" => line})

      # Give the port time to echo back
      Process.sleep(50)

      snapshot = PortWorker.snapshot(pid)
      # The cat binary echoes back whatever we send, so last_event should be updated
      assert snapshot.last_event != nil

      GenServer.stop(pid)
    end
  end
end
