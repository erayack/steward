import Config

config :steward,
  mock_agent: [],
  workers: [],
  agent_api: [
    timeout_ms: String.to_integer(System.get_env("STEWARD_AGENT_API_TIMEOUT_MS", "5000")),
    auth_token: System.get_env("STEWARD_AGENT_API_AUTH_TOKEN"),
    targets: %{}
  ],
  quarantine: [
    max_crashes: 3,
    window_ms: 60_000,
    cooldown_ms: 120_000
  ],
  run: [
    rpc_timeout_ms: 15_000,
    default_targets: [node()],
    actions_module: Steward.Actions.AgentAPIActions,
    idempotency_ttl_ms: :infinity,
    idempotency_max_ids_per_node: 10_000,
    completed_runs_max: 1_000
  ],
  audit: [
    max_events: 2_000,
    sink_enabled: false,
    sink_path: nil
  ],
  server: [
    enabled: System.get_env("STEWARD_SERVER_ENABLED", "false") == "true",
    host: System.get_env("STEWARD_SERVER_HOST", "127.0.0.1"),
    port: String.to_integer(System.get_env("STEWARD_SERVER_PORT", "4000"))
  ]

config :steward, StewardWeb.Endpoint,
  url: [host: System.get_env("STEWARD_SERVER_HOST", "127.0.0.1")],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: Phoenix.Controller, html: Phoenix.Controller],
    layout: false
  ],
  pubsub_server: Steward.PubSub,
  secret_key_base:
    System.get_env(
      "STEWARD_SECRET_KEY_BASE",
      "IKuCCjVG3xjL8o4vpmfOTw4vGG1ByxIhFAf6U/SKxwJYx2I1aTk9hBOJhHzdI9vu"
    ),
  live_view: [signing_salt: "steward-live"]
