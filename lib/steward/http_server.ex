defmodule Steward.HttpServer do
  @moduledoc "Optional Bandit HTTP server for API and LiveView endpoints."

  def child_spec(_args) do
    server = Application.fetch_env!(:steward, :server)

    Bandit.child_spec(
      plug: StewardWeb.Endpoint,
      scheme: :http,
      ip: parse_host!(server[:host] || "127.0.0.1"),
      port: server[:port] || 4000
    )
  end

  defp parse_host!(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> ip
      {:error, _reason} -> raise ArgumentError, "invalid STEWARD server host: #{inspect(host)}"
    end
  end
end
