set shell := ["zsh", "-cu"]

default: check

# Run all quality gates in check-only mode.
check: check-elixir check-rust

check-elixir:
    mix format --check-formatted
    mix compile --warnings-as-errors
    mix credo --strict
    mix test

check-rust:
    cargo fmt --manifest-path native/steward_mock_agent/Cargo.toml -- --check
    cargo clippy --manifest-path native/steward_mock_agent/Cargo.toml --all-targets -- -D warnings
    cargo test --manifest-path native/steward_mock_agent/Cargo.toml
    cargo check --manifest-path native/steward_mock_agent/Cargo.toml
