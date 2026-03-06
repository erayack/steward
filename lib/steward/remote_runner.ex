defmodule Steward.RemoteRunner do
  @moduledoc "Applies a run on the local node with idempotency checks."

  alias Steward.{RunRegistry, Types}

  @spec apply_run(Types.Run.t()) ::
          {:ok, %{optional(Types.process_id()) => Types.run_result() | term()}}
          | {:error, term()}
  def apply_run(%Types.Run{} = run) do
    case RunRegistry.apply_once(node(), run.run_id) do
      :already_applied ->
        {:ok, Map.new(run.targets, &{&1, :already_applied})}

      :applied ->
        {:ok, execute_targets(run)}
    end
  end

  def apply_run(_), do: {:error, :invalid_run}

  defp execute_targets(run) do
    actions_module = actions_module()

    Enum.reduce(run.targets, %{}, fn process_id, acc ->
      params =
        run.params
        |> Map.put(:process_id, process_id)
        |> Map.put(:run_id, run.run_id)
        |> maybe_put_desired_config_version(run.desired_config_version)

      result =
        case actions_module.apply(run.action, params) do
          :ok -> :success
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_action_result, other}}
        end

      Map.put(acc, process_id, result)
    end)
  end

  defp maybe_put_desired_config_version(params, nil), do: params

  defp maybe_put_desired_config_version(params, desired_config_version) do
    Map.put(params, :desired_config_version, desired_config_version)
  end

  defp actions_module do
    Application.get_env(:steward, :run, [])
    |> Keyword.get(:actions_module, Steward.Actions.MockAgentActions)
  end
end
