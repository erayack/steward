defmodule StewardWeb.Router do
  @moduledoc "Router for observability API and dashboard."
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, false)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  get("/health", StewardWeb.HealthController, :show)

  scope "/api/v1", StewardWeb do
    pipe_through(:api)

    get("/state", ObservabilityAPIController, :state)
    get("/runs/:run_id", ObservabilityAPIController, :run)
    post("/runs", ObservabilityAPIController, :trigger_run)
    post("/agents/register", AgentAPIController, :register)
    post("/agents/:process_id/heartbeat", AgentAPIController, :heartbeat)
    post("/agents/:process_id/events", AgentAPIController, :events)
    post("/workers/:process_id/upgrade", WorkerAPIController, :upgrade)
    get("/workers/:process_id", WorkerAPIController, :show)
  end

  scope "/", StewardWeb do
    pipe_through(:browser)
    live("/", DashboardLive, :index)
  end
end
