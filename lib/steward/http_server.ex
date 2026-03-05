defmodule Steward.HttpServer do
  @moduledoc "Optional Bandit HTTP server for observability endpoints."

  def child_spec(_args) do
    server = Application.fetch_env!(:steward, :server)

    Bandit.child_spec(
      plug: Steward.HttpServer.Plug,
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

defmodule Steward.HttpServer.Plug do
  @moduledoc false
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
