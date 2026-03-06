defmodule Steward.RunExecutor do
  @moduledoc "Validates runs, resolves targets to nodes, and fans out execution via :erpc."

  alias Steward.{ClusterMembership, RemoteRunner, Run, RunRegistry, Types}

  @spec execute(Types.Run.t()) :: {:ok, Types.Run.t()} | {:error, term()}
  def execute(%Types.Run{} = run) do
    with :ok <- validate_run(run),
         {:ok, running_run} <- Run.mark_running(run) do
      :ok = RunRegistry.mark_running(run.run_id)

      {targets_by_node, unresolved_results} = resolve_targets(run.targets)
      rpc_results = fan_out(run, targets_by_node, rpc_timeout_ms())
      results = Map.merge(unresolved_results, rpc_results)

      :ok = RunRegistry.complete_run(run.run_id, results)
      Run.complete(running_run, results)
    end
  end

  def execute(_), do: {:error, :invalid_run}

  defp validate_run(%Types.Run{run_id: run_id, action: action, targets: targets})
       when is_binary(run_id) and run_id != "" and is_list(targets) and targets != [] do
    if Steward.Actions.known_action?(action), do: :ok, else: {:error, :invalid_action}
  end

  defp validate_run(_), do: {:error, :invalid_run}

  defp fan_out(run, targets_by_node, timeout_ms) do
    Enum.reduce(targets_by_node, %{}, fn {target_node, targets}, acc ->
      target_run = %{run | targets: targets}

      node_results =
        case rpc_apply(target_node, target_run, timeout_ms) do
          {:ok, response} ->
            normalize_response(response, targets)

          {:error, reason} ->
            Map.new(targets, &{&1, {:rpc_error, reason}})
        end

      Map.merge(acc, node_results)
    end)
  end

  defp rpc_apply(target_node, run, timeout_ms) do
    case :erpc.call(target_node, RemoteRunner, :apply_run, [run], timeout_ms) do
      {:ok, response} when is_map(response) -> {:ok, response}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_reply, other}}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp normalize_response(response, targets) do
    Enum.reduce(targets, %{}, fn target, acc ->
      value = Map.get(response, target, {:error, :missing_target_result})
      Map.put(acc, target, value)
    end)
  end

  defp resolve_targets(targets) do
    processes_by_node =
      ClusterMembership.snapshot()
      |> Map.get(:processes_by_node, %{})

    Enum.reduce(targets, {%{}, %{}}, fn target, {targets_by_node, unresolved} ->
      candidate_nodes = nodes_for_target(processes_by_node, target)

      case candidate_nodes do
        [] ->
          {targets_by_node, Map.put(unresolved, target, :not_found)}

        [target_node] ->
          updated_targets = Map.update(targets_by_node, target_node, [target], &[target | &1])
          {updated_targets, unresolved}

        _ ->
          {targets_by_node,
           Map.put(unresolved, target, {:error, {:ambiguous_target, candidate_nodes}})}
      end
    end)
    |> normalize_targets_by_node()
  end

  defp normalize_targets_by_node({targets_by_node, unresolved}) do
    normalized =
      Map.new(targets_by_node, fn {target_node, targets} ->
        {target_node, Enum.reverse(targets)}
      end)

    {normalized, unresolved}
  end

  defp nodes_for_target(processes_by_node, target) do
    processes_by_node
    |> Enum.reduce([], fn
      {target_node, %MapSet{} = process_ids}, acc ->
        if MapSet.member?(process_ids, target), do: [target_node | acc], else: acc

      _, acc ->
        acc
    end)
    |> Enum.sort()
  end

  defp rpc_timeout_ms do
    Application.get_env(:steward, :run, [])
    |> Keyword.get(:rpc_timeout_ms, 15_000)
  end
end
