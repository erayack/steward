defmodule Steward.HttpServer.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Steward.HttpServer.Plug, as: HealthPlug

  describe "GET /health" do
    test "responds with 200 and \"ok\"" do
      conn = conn(:get, "/health") |> HealthPlug.call(HealthPlug.init([]))

      assert conn.status == 200
      assert conn.resp_body == "ok"
    end
  end

  describe "GET /unknown" do
    test "responds with 404 and \"not found\"" do
      conn = conn(:get, "/unknown") |> HealthPlug.call(HealthPlug.init([]))

      assert conn.status == 404
      assert conn.resp_body == "not found"
    end
  end
end
