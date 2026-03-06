defmodule StewardWeb.HealthController do
  @moduledoc false
  use StewardWeb, :controller

  def show(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
