defmodule Steward.Run do
  @moduledoc "Run model with explicit lifecycle transitions."

  alias Steward.Types.Run, as: RunType

  @spec new(map()) :: {:ok, RunType.t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, run_id} <- fetch_non_empty_binary(attrs, :run_id),
         {:ok, action} <- fetch_atom(attrs, :action),
         {:ok, targets} <- fetch_targets(attrs) do
      run = %RunType{
        run_id: run_id,
        action: action,
        targets: targets,
        params: fetch_map(attrs, :params, %{}),
        desired_config_version: fetch_optional_binary(attrs, :desired_config_version),
        status: :pending,
        results: %{},
        started_at: nil,
        finished_at: nil
      }

      {:ok, run}
    end
  end

  def new(_), do: {:error, :invalid_attributes}

  @spec mark_running(RunType.t()) :: {:ok, RunType.t()} | {:error, :invalid_transition}
  def mark_running(%RunType{status: :pending} = run) do
    {:ok, %{run | status: :running, started_at: run.started_at || DateTime.utc_now()}}
  end

  def mark_running(%RunType{}), do: {:error, :invalid_transition}

  @spec complete(RunType.t(), map()) :: {:ok, RunType.t()} | {:error, :invalid_transition}
  def complete(%RunType{status: :running} = run, results) when is_map(results) do
    now = DateTime.utc_now()

    {:ok,
     %{run | status: :done, results: results, finished_at: now, started_at: run.started_at || now}}
  end

  def complete(%RunType{}, _results), do: {:error, :invalid_transition}

  defp fetch_non_empty_binary(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_atom(attrs, key) do
    case Map.get(attrs, key) do
      value when is_atom(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_targets(attrs) do
    case Map.get(attrs, :targets) do
      targets when is_list(targets) and targets != [] ->
        validate_targets(targets)

      _ ->
        {:error, {:invalid_field, :targets}}
    end
  end

  defp valid_targets?(targets) do
    Enum.all?(targets, fn target -> is_binary(target) and target != "" end)
  end

  defp validate_targets(targets) do
    if valid_targets?(targets), do: {:ok, targets}, else: {:error, {:invalid_field, :targets}}
  end

  defp fetch_map(attrs, key, default) do
    case Map.get(attrs, key, default) do
      value when is_map(value) -> value
      _ -> default
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
