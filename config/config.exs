import Config

default_mock_agent_path =
  Enum.find(
    [
      "native/steward_mock_agent/target/debug/steward_mock_agent",
      "native/steward_mock_agent/target/release/steward_mock_agent"
    ],
    &File.exists?/1
  ) || "native/steward_mock_agent/target/debug/steward_mock_agent"

config :steward,
  mock_agent: [
    path:
      System.get_env(
        "STEWARD_MOCK_AGENT_PATH",
        default_mock_agent_path
      )
  ],
  quarantine: [
    max_crashes: 3,
    window_ms: 60_000,
    cooldown_ms: 120_000
  ],
  run: [
    rpc_timeout_ms: 15_000,
    default_targets: [node()]
  ],
  server: [
    enabled: System.get_env("STEWARD_SERVER_ENABLED", "false") == "true",
    host: System.get_env("STEWARD_SERVER_HOST", "127.0.0.1"),
    port: String.to_integer(System.get_env("STEWARD_SERVER_PORT", "4000"))
  ]
