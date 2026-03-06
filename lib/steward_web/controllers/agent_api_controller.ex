defmodule StewardWeb.AgentAPIController do
  @moduledoc false
  use StewardWeb, :controller

  alias Steward.{ClusterMembership, StatusStore}

  def register(conn, params) do
    with {:ok, process_id} <- fetch_process_id(params) do
      now = DateTime.utc_now()
      metadata = Map.get(params, "metadata") || %{}

      ClusterMembership.attach_process(node(), process_id)

      snapshot =
        process_id
        |> base_snapshot()
        |> Map.put(:status, :up)
        |> Map.put(:last_heartbeat_at, now)
        |> Map.put(:last_event, %{type: :agent_registered, at: now, metadata: metadata})
        |> Map.put(:metadata, metadata)

      StatusStore.upsert_process_snapshot(process_id, snapshot)
      StatusStore.record_control_event(process_id, :agent_registered, %{metadata: metadata})

      json(conn, %{ok: true, process_id: process_id})
    else
      {:error, :missing_process_id} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "missing_process_id"})
    end
  end

  def heartbeat(conn, %{"process_id" => process_id} = params) do
    with {:ok, process_id} <- fetch_process_id(%{"process_id" => process_id}) do
      ts = parse_timestamp(Map.get(params, "ts"), DateTime.utc_now())

      ClusterMembership.attach_process(node(), process_id)

      snapshot =
        process_id
        |> base_snapshot()
        |> Map.put(:status, :up)
        |> Map.put(:last_heartbeat_at, ts)
        |> Map.put(:last_event, %{type: :heartbeat, at: ts})

      StatusStore.upsert_process_snapshot(process_id, snapshot)
      StatusStore.record_control_event(process_id, :heartbeat, %{at: DateTime.to_iso8601(ts)})

      json(conn, %{ok: true, process_id: process_id})
    else
      {:error, :missing_process_id} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "missing_process_id"})
    end
  end

  def events(conn, %{"process_id" => process_id} = params) do
    with {:ok, process_id} <- fetch_process_id(%{"process_id" => process_id}) do
      events = normalize_events(params)
      now = DateTime.utc_now()

      Enum.each(events, fn event ->
        kind = Map.get(event, "kind") || Map.get(event, :kind) || "event"
        payload = Map.get(event, "payload") || Map.get(event, :payload) || %{}

        StatusStore.record_control_event(process_id, :agent_event, %{
          kind: kind,
          payload: payload
        })
      end)

      snapshot =
        process_id
        |> base_snapshot()
        |> Map.put(:status, :up)
        |> Map.put(:last_event, %{type: :agent_event, count: length(events), at: now})

      StatusStore.upsert_process_snapshot(process_id, snapshot)
      json(conn, %{ok: true, process_id: process_id, accepted: length(events)})
    else
      {:error, :missing_process_id} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "missing_process_id"})
    end
  end

  defp base_snapshot(process_id) do
    StatusStore.get_process_snapshot(process_id)
    |> case do
      nil ->
        %{
          process_id: process_id,
          status: :down,
          last_heartbeat_at: nil,
          restart_count: 0,
          quarantined_until_ms: nil,
          last_event: nil
        }

      existing ->
        existing
    end
    |> Map.put(:process_id, process_id)
    |> Map.put_new(:restart_count, 0)
    |> Map.put_new(:quarantined_until_ms, nil)
  end

  defp fetch_process_id(params) do
    case Map.get(params, "process_id") || Map.get(params, :process_id) do
      process_id when is_binary(process_id) and process_id != "" -> {:ok, process_id}
      _ -> {:error, :missing_process_id}
    end
  end

  defp normalize_events(%{"events" => events}) when is_list(events), do: events
  defp normalize_events(%{events: events}) when is_list(events), do: events
  defp normalize_events(params), do: [params]

  defp parse_timestamp(value, default) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> default
    end
  end

  defp parse_timestamp(_, default), do: default
end
