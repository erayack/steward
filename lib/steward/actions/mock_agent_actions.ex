defmodule Steward.Actions.MockAgentActions do
  @moduledoc "PoC action backend that dispatches command JSONL to local PortWorker instances."
  @behaviour Steward.Actions

  @worker_registry Steward.WorkerRegistry

  @impl true
  def apply(action, params) when is_atom(action) and is_map(params) do
    with {:ok, process_id} <- fetch_process_id(params) do
      Steward.PortWorker.send_command(worker_server(process_id), command(action, params))
    end
  end

  def apply(_action, _params), do: {:error, :invalid_action_payload}

  defp fetch_process_id(params) do
    case Map.get(params, :process_id) || Map.get(params, "process_id") do
      process_id when is_binary(process_id) and process_id != "" -> {:ok, process_id}
      _ -> {:error, :missing_process_id}
    end
  end

  defp worker_server(process_id), do: {:via, Registry, {@worker_registry, process_id}}

  defp command(action, params) do
    %{
      "kind" => "command",
      "fields" => %{
        "action" => Atom.to_string(action),
        "params" => stringify_keys(params)
      }
    }
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
