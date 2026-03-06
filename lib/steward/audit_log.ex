defmodule Steward.AuditLog do
  @moduledoc "Optional JSONL file sink for audit events."

  @spec append_event(map()) :: :ok | {:error, term()}
  def append_event(event) when is_map(event) do
    with {:enabled, path} <- sink_config(),
         {:ok, payload} <- Jason.encode(json_safe(event)) do
      File.write(path, payload <> "\n", [:append])
    else
      :disabled -> :ok
      {:error, _reason} = error -> error
    end
  end

  def append_event(_event), do: {:error, :invalid_event}

  defp sink_config do
    cfg = Application.get_env(:steward, :audit, [])
    enabled? = Keyword.get(cfg, :sink_enabled, false)
    path = Keyword.get(cfg, :sink_path)

    if enabled? and is_binary(path) and path != "" do
      {:enabled, path}
    else
      :disabled
    end
  end

  defp json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp json_safe(%_{} = struct) do
    struct |> Map.from_struct() |> json_safe()
  end

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {normalize_key(key), json_safe(value)}
    end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp json_safe(pid) when is_pid(pid), do: inspect(pid)
  defp json_safe(ref) when is_reference(ref), do: inspect(ref)
  defp json_safe(port) when is_port(port), do: inspect(port)
  defp json_safe(fun) when is_function(fun), do: inspect(fun)
  defp json_safe(other), do: other

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key
end
