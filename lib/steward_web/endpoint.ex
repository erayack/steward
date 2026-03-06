defmodule StewardWeb.Endpoint do
  @moduledoc "Phoenix endpoint for API and LiveView observability surfaces."
  use Phoenix.Endpoint, otp_app: :steward

  @session_options [
    store: :cookie,
    key: "_steward_key",
    signing_salt: "steward-live"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:steward, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(StewardWeb.Router)
end
