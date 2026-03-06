defmodule StewardWeb.Presenter do
  @moduledoc "Projection layer shared by observability API and LiveView dashboard."

  alias Steward.{Actions, RunExecutor, RunRegistry, StatusStore}

  @default_timeout 5_000

  @spec state_payload(timeout()) :: map()
  def state_payload(timeout \\ @default_timeout) when is_integer(timeout) and timeout > 0 do
    snapshot = StatusStore.snapshot(timeout)

    process_rows =
      snapshot.processes
      |> Map.values()
      |> Enum.map(&project_process_row/1)
      |> Enum.sort_by(& &1.process_id)

    node_cards =
      snapshot.membership.nodes
      |> Enum.map(fn {node_id, status} ->
        process_ids =
          snapshot.membership.processes_by_node
          |> Map.get(node_id, MapSet.new())
          |> MapSet.to_list()
          |> Enum.sort()

        %{
          node: Atom.to_string(node_id),
          status: normalize_status(status),
          process_count: length(process_ids),
          process_ids: process_ids
        }
      end)
      |> Enum.sort_by(& &1.node)

    run_feed = project_run_feed(snapshot.runs)

    %{
      summary: %{
        nodes_total: length(node_cards),
        nodes_up: Enum.count(node_cards, &(&1.status == "up")),
        processes_total: length(process_rows),
        processes_up: Enum.count(process_rows, &(&1.status == "up")),
        active_runs: map_size(snapshot.runs.active_runs),
        completed_runs: map_size(snapshot.runs.completed_runs)
      },
      nodes: node_cards,
      processes: process_rows,
      runs: run_feed,
      updated_at_ms: snapshot.updated_at_ms
    }
  end

  @spec run_payload(String.t(), timeout()) :: {:ok, map()} | {:error, :not_found}
  def run_payload(run_id, timeout \\ @default_timeout)
      when is_binary(run_id) and run_id != "" and is_integer(timeout) and timeout > 0 do
    runs = StatusStore.snapshot(timeout).runs

    with nil <- Map.get(runs.active_runs, run_id),
         nil <- Map.get(runs.completed_runs, run_id) do
      {:error, :not_found}
    else
      run when is_map(run) ->
        {:ok, project_run(run)}
    end
  end

  @spec trigger_run_payload(map()) :: {:ok, map()} | {:error, term()}
  def trigger_run_payload(attrs) when is_map(attrs) do
    with {:ok, run_attrs} <- normalize_run_attrs(attrs),
         {:ok, run} <- RunRegistry.create_run(run_attrs),
         {:ok, executed_run} <- RunExecutor.execute(run) do
      {:ok, %{run: project_run(executed_run)}}
    end
  end

  defp normalize_run_attrs(attrs) do
    with {:ok, action} <- normalize_action(Map.get(attrs, "action") || Map.get(attrs, :action)),
         {:ok, targets} <-
           normalize_targets(Map.get(attrs, "targets") || Map.get(attrs, :targets)) do
      {:ok,
       %{
         run_id: Map.get(attrs, "run_id") || Map.get(attrs, :run_id) || generate_run_id(),
         action: action,
         targets: targets,
         params: Map.get(attrs, "params") || Map.get(attrs, :params) || %{},
         desired_config_version:
           Map.get(attrs, "desired_config_version") || Map.get(attrs, :desired_config_version)
       }}
    end
  end

  defp normalize_action(action) do
    case Actions.parse_action(action) do
      {:ok, normalized_action} -> {:ok, normalized_action}
      {:error, :invalid_action} -> {:error, {:invalid_field, :action}}
    end
  end

  defp normalize_targets(nil) do
    targets = list_membership_targets()

    normalize_targets(targets)
  end

  defp normalize_targets(targets) when is_list(targets) do
    case Enum.filter(targets, &(is_binary(&1) and &1 != "")) do
      [] -> {:error, {:invalid_field, :targets}}
      valid -> {:ok, valid}
    end
  end

  defp normalize_targets(_), do: {:error, {:invalid_field, :targets}}

  defp list_membership_targets do
    Steward.ClusterMembership.snapshot()
    |> Map.get(:processes_by_node, %{})
    |> Map.values()
    |> Enum.flat_map(fn
      %MapSet{} = process_ids -> MapSet.to_list(process_ids)
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp generate_run_id do
    "run_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp project_process_row(snapshot) do
    heartbeat_age_ms =
      case Map.get(snapshot, :last_heartbeat_at) do
        %DateTime{} = ts -> DateTime.diff(DateTime.utc_now(), ts, :millisecond)
        _ -> nil
      end

    %{
      process_id: snapshot.process_id,
      status: normalize_status(snapshot.status),
      heartbeat_age_ms: heartbeat_age_ms,
      restart_count: snapshot.restart_count,
      quarantined_until_ms: snapshot.quarantined_until_ms
    }
  end

  defp project_run_feed(runs) do
    (Map.values(runs.active_runs) ++ Map.values(runs.completed_runs))
    |> Enum.map(&project_run/1)
    |> Enum.sort_by(fn run -> run.started_at || run.finished_at || "" end, :desc)
  end

  defp project_run(run) do
    %{
      run_id: run.run_id,
      action: to_string(run.action),
      targets: run.targets,
      status: normalize_status(run.status),
      results: run.results || %{},
      started_at: format_dt(run.started_at),
      finished_at: format_dt(run.finished_at)
    }
  end

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status), do: to_string(status)

  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(_), do: nil
end
