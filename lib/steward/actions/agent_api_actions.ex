defmodule Steward.Actions.AgentAPIActions do
  @moduledoc "Action backend that dispatches run commands to external agent APIs."
  @behaviour Steward.Actions

  alias Steward.AgentAPIClient

  @impl true
  def apply(action, params) when is_atom(action) and is_map(params) do
    with {:ok, process_id} <- fetch_process_id(params),
         {:ok, base_url} <- resolve_base_url(process_id) do
      AgentAPIClient.post_json(
        base_url,
        "/v1/actions",
        command(action, params),
        timeout_ms: timeout_ms(),
        auth_token: auth_token()
      )
    end
  end

  def apply(_action, _params), do: {:error, :invalid_action_payload}

  defp fetch_process_id(params) do
    case Map.get(params, :process_id) || Map.get(params, "process_id") do
      process_id when is_binary(process_id) and process_id != "" -> {:ok, process_id}
      _ -> {:error, :missing_process_id}
    end
  end

  defp resolve_base_url(process_id) do
    api_cfg = Application.get_env(:steward, :agent_api, [])

    with nil <- Keyword.get(api_cfg, :targets, %{}) |> Map.get(process_id),
         nil <- worker_base_url(process_id) do
      {:error, {:unknown_agent_target, process_id}}
    else
      base_url when is_binary(base_url) and base_url != "" -> {:ok, base_url}
      _ -> {:error, {:invalid_agent_target, process_id}}
    end
  end

  defp worker_base_url(process_id) do
    Application.get_env(:steward, :workers, [])
    |> Enum.find_value(fn worker ->
      normalized = Steward.WorkerSupervisor.normalize_worker_spec(worker)

      case normalized do
        [%{process_id: ^process_id, transport: :api, base_url: base_url}] -> base_url
        _ -> nil
      end
    end)
  end

  defp command(action, params) do
    %{
      "action" => Atom.to_string(action),
      "params" => stringify_keys(params)
    }
  end

  defp timeout_ms do
    Application.get_env(:steward, :agent_api, [])
    |> Keyword.get(:timeout_ms, 5_000)
  end

  defp auth_token do
    Application.get_env(:steward, :agent_api, [])
    |> Keyword.get(:auth_token)
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
