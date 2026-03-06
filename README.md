# Steward

Steward is an Elixir-based control plane for orchestrating remediation runs across managed agents.  
It now supports an API-first integration model, so you can run it without the Rust mock binary.

## Key Features

- OTP-managed orchestration and run lifecycle.
- Distributed run fan-out via `:erpc`.
- API-based action dispatch to external agents.
- Real-time observability API + LiveView dashboard.
- Agent telemetry ingestion (`register`, `heartbeat`, `events`).

## Architecture

- **Control Plane (Elixir)**: Run registry, fan-out, status aggregation, dashboard.
- **Agent API Backend**: Steward dispatches actions to agent HTTP endpoints.
- **Observability Layer**: `/api/v1/state`, run APIs, and dashboard projections.
- **Optional Port Backend**: Local Port workers are still supported when explicitly configured.

## Getting Started (No Rust Required)

### Prerequisites

- Elixir 1.16+
- Node.js (if you build frontend assets)

### Setup

```bash
mix deps.get
export STEWARD_SERVER_ENABLED=true
export STEWARD_SERVER_PORT=4000
iex -S mix
```

Open `http://localhost:4000/`.

## Configuration

Configuration is in `config/config.exs`.

### Server env vars

- `STEWARD_SERVER_ENABLED` (default `false`)
- `STEWARD_SERVER_HOST` (default `127.0.0.1`)
- `STEWARD_SERVER_PORT` (default `4000`)
- `STEWARD_SECRET_KEY_BASE` (optional, has a dev fallback)

### Agent API env vars

- `STEWARD_AGENT_API_TIMEOUT_MS` (default `5000`)
- `STEWARD_AGENT_API_AUTH_TOKEN` (optional bearer token for outbound calls)

### Worker configuration

API workers are configured under `:workers`, for example:

```elixir
config :steward,
  workers: [
    %{process_id: "agent-a", transport: :api, base_url: "http://127.0.0.1:5051"},
    %{process_id: "agent-b", transport: :api, base_url: "http://127.0.0.1:5052"}
  ]
```

You can also provide `agent_api.targets` map overrides by `process_id`.

### Legacy mock-agent example (optional)

If you want to run the old Port-based integration for local debugging, configure a Port worker explicitly:

```elixir
config :steward,
  workers: [
    %{
      process_id: "mock_agent",
      binary_path: "native/steward_mock_agent/target/debug/steward_mock_agent",
      args: []
    }
  ],
  run: [
    actions_module: Steward.Actions.MockAgentActions
  ]
```

Then build the binary:

```bash
cd native/steward_mock_agent
cargo build
```

## API Endpoints

### Observability and runs

- `GET /health`
- `GET /api/v1/state`
- `GET /api/v1/runs/:run_id`
- `POST /api/v1/runs`

### Agent telemetry (inbound)

- `POST /api/v1/agents/register`
- `POST /api/v1/agents/:process_id/heartbeat`
- `POST /api/v1/agents/:process_id/events`

## CLI

Build:

```bash
mix escript.build
```

Commands:

- `./steward start --port 4000`
- `./steward workers list`
- `./steward run --action panic_fail_open --targets agent-a,agent-b --params '{"mode":"safe"}'`

## Environment Files (`.env`)

Steward does **not** auto-load a `.env` file today.  
It reads environment variables via `System.get_env/2` from `config/config.exs`.

Use one of these patterns:

- `source .env` before starting.
- `direnv` / shell profile exports.
- Docker/Kubernetes environment injection.

If you want auto `.env` loading, add a dotenv loader in your dev startup workflow.

## Testing

```bash
mix test
```

## Project Structure

- `lib/steward/`: core orchestration and worker control
- `lib/steward_web/`: endpoint, controllers, LiveView
- `native/steward_mock_agent/`: optional mock binary
- `test/`: test suite
