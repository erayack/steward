defmodule Steward.Types do
  @moduledoc "Shared domain contracts for process, node, run, and port payload state."

  @type node_id :: node()
  @type process_id :: String.t()
  @type run_id :: String.t()

  @type proc_status :: :up | :restarting | :quarantined | :down
  @type node_status :: :up | :down
  @type run_status :: :pending | :running | :done
  @type run_trigger_source :: :manual | :metric | :trace | :operator
  @type run_trigger_reason :: map() | String.t()

  @type port_kind :: :heartbeat | :metric | :event | :error
  @type run_result ::
          :success
          | :fail
          | :timeout
          | :already_applied
          | :not_found
          | :rpc_error
  @type run_summary :: %{
          run_id: run_id(),
          action: atom(),
          targets: [process_id()],
          status: run_status(),
          results: %{optional(process_id()) => run_result() | term()},
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          trigger_source: run_trigger_source() | nil,
          trigger_reason: run_trigger_reason() | nil,
          meta: map()
        }

  @type process_snapshot :: %{
          optional(:metrics) => map(),
          optional(:binary_generation) => non_neg_integer() | nil,
          optional(:upgrade_state) => atom() | String.t() | nil,
          optional(:active_binary_path) => String.t() | nil,
          optional(atom()) => term()
        }

  @type trace_anomaly :: %{
          required(:cluster_id) => String.t(),
          required(:signal) => atom() | String.t(),
          required(:severity) => atom() | String.t(),
          required(:affected_process_ids) => [process_id()],
          required(:window_start) => DateTime.t() | integer() | String.t(),
          required(:window_end) => DateTime.t() | integer() | String.t(),
          optional(atom()) => term()
        }

  @type run :: Steward.Types.Run.t()
  @type port_envelope :: Steward.Types.PortEnvelope.t()
end

defmodule Steward.Types.Run do
  @moduledoc "Run model shared by execution, state, and presentation layers."

  @enforce_keys [:run_id, :action, :targets]
  defstruct [
    :run_id,
    :action,
    :targets,
    :params,
    :desired_config_version,
    :status,
    :results,
    :started_at,
    :finished_at,
    :trigger_source,
    :trigger_reason
  ]

  @type t :: %__MODULE__{
          run_id: Steward.Types.run_id(),
          action: atom(),
          targets: [Steward.Types.process_id()],
          params: map(),
          desired_config_version: String.t() | nil,
          status: Steward.Types.run_status(),
          results: %{optional(Steward.Types.process_id()) => Steward.Types.run_result() | term()},
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          trigger_source: Steward.Types.run_trigger_source() | nil,
          trigger_reason: Steward.Types.run_trigger_reason() | nil
        }
end

defmodule Steward.Types.PortEnvelope do
  @moduledoc "Envelope for line-oriented port telemetry emitted by managed processes."

  @enforce_keys [:ts, :level, :kind, :fields]
  defstruct [:ts, :level, :kind, :fields]

  @type t :: %__MODULE__{
          ts: DateTime.t(),
          level: :debug | :info | :notice | :warning | :error | :critical | :alert | :emergency,
          kind: Steward.Types.port_kind(),
          fields: map()
        }
end
