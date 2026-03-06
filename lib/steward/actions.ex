defmodule Steward.Actions do
  @moduledoc "Behavior contract and helpers for run action handlers."

  @known_actions [:update_vantage_policy, :set_chronos_window, :panic_fail_open]
  @known_actions_by_name Map.new(@known_actions, fn action -> {Atom.to_string(action), action} end)

  @callback apply(action :: atom(), params :: map()) :: :ok | {:error, term()}

  @spec known_actions() :: [atom()]
  def known_actions, do: @known_actions

  @spec known_action?(atom()) :: boolean()
  def known_action?(action), do: action in @known_actions

  @spec parse_action(atom() | String.t()) :: {:ok, atom()} | {:error, :invalid_action}
  def parse_action(action) when is_atom(action) do
    if known_action?(action), do: {:ok, action}, else: {:error, :invalid_action}
  end

  def parse_action(action) when is_binary(action) do
    case Map.fetch(@known_actions_by_name, action) do
      {:ok, known_action} -> {:ok, known_action}
      :error -> {:error, :invalid_action}
    end
  end

  def parse_action(_), do: {:error, :invalid_action}
end
