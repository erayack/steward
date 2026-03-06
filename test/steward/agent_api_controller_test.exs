defmodule Steward.AgentAPIControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Steward.StatusStore
  alias StewardWeb.Router

  test "POST /api/v1/agents/register records process snapshot and membership" do
    process_id = "agent_register_#{System.unique_integer([:positive])}"

    conn =
      conn(:post, "/api/v1/agents/register", %{
        "process_id" => process_id,
        "metadata" => %{"region" => "eu-west-1"}
      })
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 200
    assert %{"ok" => true, "process_id" => ^process_id} = Jason.decode!(conn.resp_body)

    snapshot = StatusStore.get_process_snapshot(process_id)
    assert snapshot.status == :up
    assert snapshot.metadata == %{"region" => "eu-west-1"}

    assert process_id in attached_processes()
  end

  test "POST /api/v1/agents/:process_id/heartbeat updates last heartbeat" do
    process_id = "agent_hb_#{System.unique_integer([:positive])}"
    ts = "2026-03-05T12:00:00Z"

    conn =
      conn(:post, "/api/v1/agents/#{process_id}/heartbeat", %{"ts" => ts})
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 200
    assert %{"ok" => true, "process_id" => ^process_id} = Jason.decode!(conn.resp_body)

    snapshot = StatusStore.get_process_snapshot(process_id)
    assert snapshot.status == :up
    assert DateTime.to_iso8601(snapshot.last_heartbeat_at) == ts
    assert process_id in attached_processes()
  end

  test "POST /api/v1/agents/:process_id/events records control events" do
    process_id = "agent_events_#{System.unique_integer([:positive])}"

    conn =
      conn(:post, "/api/v1/agents/#{process_id}/events", %{
        "events" => [
          %{"kind" => "metric", "payload" => %{"cpu" => 42}},
          %{"kind" => "event", "payload" => %{"name" => "drift_detected"}}
        ]
      })
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 200

    events = StatusStore.list_control_events(process_id)
    assert length(events) == 2
    assert Enum.all?(events, &(&1.kind == :agent_event))

    snapshot = StatusStore.get_process_snapshot(process_id)
    assert snapshot.status == :up
    assert snapshot.last_event.type == :agent_event
  end

  defp attached_processes do
    Steward.ClusterMembership.snapshot()
    |> Map.get(:processes_by_node, %{})
    |> Map.get(node(), MapSet.new())
    |> MapSet.to_list()
  end
end
