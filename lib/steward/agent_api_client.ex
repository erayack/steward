defmodule Steward.AgentAPIClient do
  @moduledoc "Minimal HTTP JSON client for agent API interactions."

  @spec post_json(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def post_json(base_url, path, payload, opts \\ [])
      when is_binary(base_url) and is_binary(path) and is_map(payload) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)
    auth_token = Keyword.get(opts, :auth_token)

    url = build_url(base_url, path)
    body = Jason.encode!(payload)

    headers =
      [
        {~c"content-type", ~c"application/json"},
        {~c"accept", ~c"application/json"}
      ]
      |> maybe_put_auth(auth_token)

    request = {String.to_charlist(url), headers, ~c"application/json", body}
    http_opts = [timeout: timeout_ms, connect_timeout: timeout_ms]
    request_opts = [body_format: :binary]

    case :httpc.request(:post, request, http_opts, request_opts) do
      {:ok, {{_http_version, status, _reason_phrase}, _resp_headers, _resp_body}}
      when status in 200..299 ->
        :ok

      {:ok, {{_http_version, status, _reason_phrase}, _resp_headers, resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp build_url(base_url, path) do
    String.trim_trailing(base_url, "/") <> "/" <> String.trim_leading(path, "/")
  end

  defp maybe_put_auth(headers, token) when is_binary(token) and token != "" do
    [{~c"authorization", ~c"Bearer " ++ String.to_charlist(token)} | headers]
  end

  defp maybe_put_auth(headers, _), do: headers
end
