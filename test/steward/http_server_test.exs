defmodule Steward.HttpServer.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias StewardWeb.Router

  describe "GET /health" do
    test "responds with 200 and \"ok\"" do
      conn = conn(:get, "/health") |> Router.call(Router.init([]))

      assert conn.status == 200
      assert conn.resp_body == "ok"
    end
  end

  describe "GET /unknown" do
    test "raises no route error" do
      assert_raise Phoenix.Router.NoRouteError, fn ->
        conn(:get, "/unknown") |> Router.call(Router.init([]))
      end
    end
  end
end
