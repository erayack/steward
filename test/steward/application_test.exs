defmodule Steward.ApplicationTest do
  use ExUnit.Case, async: true

  describe "maybe_http_server/1" do
    test "returns endpoint and http server when enabled" do
      assert Steward.Application.maybe_http_server(enabled: true) == [
               StewardWeb.Endpoint,
               Steward.HttpServer
             ]
    end

    test "returns no children when disabled" do
      assert Steward.Application.maybe_http_server(enabled: false) == []
    end
  end
end
