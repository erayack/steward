defmodule Steward.SelfHealing.AutomationEngine do
  @moduledoc "Evaluates runtime signals and orchestrates self-healing actions."
  use GenServer

  alias Steward.{Actions, RunExecutor, RunRegistry, StatusStore}
  alias StewardWeb.ObservabilityPubSub

  @type state :: %{
          enabled: boolean(),
          evaluation_interval_ms: pos_integer(),
          snapshot_timeout_ms: pos_integer(),
          leader_mode: atom(),
          cooldown_ms: non_neg_integer(),
          vantage_drop_threshold_pct: float(),
          default_action: atom(),
          self_healing: keyword(),
          trace_analysis: keyword(),
          hot_swap: keyword(),
          timer_ref: reference() | nil,
          last_vantage_pct: float() | nil,
          last_trigger_ms: integer() | nil,
          last_trigger_fingerprint: String.t() | nil
        }

  @default_evaluation_interval_ms 5_000
  @default_snapshot_timeout_ms 5_000
  @default_cooldown_ms 30_000
  @default_vantage_drop_threshold_pct 25.0
  @default_action :panic_fail_open
  @default_leader_mode :lowest_node
  @default_automation_id :vantage_drop
  @vantage_metric_keys [
    :vantage_pct,
    "vantage_pct",
    :vantage_percent,
    "vantage_percent",
    :vantage,
    "vantage",
    :vantage_health_pct,
    "vantage_health_pct",
    :vantage_success_pct,
    "vantage_success_pct",
    :vantage_success_ratio,
    "vantage_success_ratio"
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec evaluate_snapshot(map()) :: :noop | {:trigger, map()}
  def evaluate_snapshot(snapshot) when is_map(snapshot) do
    current_vantage_pct = fetch_number(snapshot, :current_vantage_pct)
    previous_vantage_pct = fetch_number(snapshot, :previous_vantage_pct)

    threshold_pct =
      fetch_number(snapshot, :vantage_drop_threshold_pct) || @default_vantage_drop_threshold_pct

    targets = normalize_targets(Map.get(snapshot, :targets))
    action = normalize_action(Map.get(snapshot, :default_action))
    automation_id = Map.get(snapshot, :automation_id, @default_automation_id)
    params = normalize_params(Map.get(snapshot, :params, %{}))
    cluster_id = fetch_binary(snapshot, :cluster_id)

    cond do
      is_nil(current_vantage_pct) ->
        :noop

      is_nil(previous_vantage_pct) ->
        :noop

      previous_vantage_pct <= 0.0 ->
        :noop

      targets == [] ->
        :noop

      true ->
        drop_pct = vantage_drop_pct(previous_vantage_pct, current_vantage_pct)

        if drop_pct >= threshold_pct and current_vantage_pct < previous_vantage_pct do
          trigger_reason =
            %{
              signal: :vantage_drop_pct,
              previous_vantage_pct: previous_vantage_pct,
              current_vantage_pct: current_vantage_pct,
              drop_pct: drop_pct,
              threshold_pct: threshold_pct
            }
            |> maybe_put(:cluster_id, cluster_id)

          run_params =
            params
            |> Map.put_new(:automation_id, automation_id)
            |> maybe_put(:cluster_id, cluster_id)

          fingerprint = fingerprint_for(trigger_reason, targets)

          {:trigger,
           %{
             automation_id: automation_id,
             action: action,
             targets: targets,
             trigger_source: :metric,
             trigger_reason: trigger_reason,
             params: run_params,
             fingerprint: fingerprint
           }}
        else
          :noop
        end
    end
  end

  def evaluate_snapshot(_snapshot), do: :noop

  @spec trigger_run(atom(), [String.t()], map()) ::
          {:ok, Steward.Types.Run.t()} | {:error, term()}
  def trigger_run(action, targets, context)
      when is_atom(action) and is_list(targets) and is_map(context) do
    with :ok <- ensure_known_action(action),
         {:ok, normalized_targets} <- normalize_non_empty_targets(targets),
         {:ok, run_attrs} <- build_run_attrs(action, normalized_targets, context),
         {:ok, run} <- RunRegistry.create_run(run_attrs) do
      RunExecutor.execute(run)
    end
  end

  def trigger_run(_action, _targets, _context), do: {:error, :invalid_trigger_payload}

  @impl true
  def init(opts) do
    self_healing =
      Keyword.get(opts, :self_healing, Application.get_env(:steward, :self_healing, []))

    state = %{
      enabled: Keyword.get(self_healing, :enabled, false),
      evaluation_interval_ms:
        Keyword.get(self_healing, :evaluation_interval_ms, @default_evaluation_interval_ms),
      snapshot_timeout_ms:
        Keyword.get(self_healing, :snapshot_timeout_ms, @default_snapshot_timeout_ms),
      leader_mode: Keyword.get(self_healing, :leader_mode, @default_leader_mode),
      cooldown_ms: Keyword.get(self_healing, :cooldown_ms, @default_cooldown_ms),
      vantage_drop_threshold_pct:
        to_float(
          Keyword.get(
            self_healing,
            :vantage_drop_threshold_pct,
            @default_vantage_drop_threshold_pct
          )
        ),
      default_action:
        normalize_action(Keyword.get(self_healing, :default_action, @default_action)),
      self_healing: self_healing,
      trace_analysis:
        Keyword.get(opts, :trace_analysis, Application.get_env(:steward, :trace_analysis, [])),
      hot_swap: Keyword.get(opts, :hot_swap, Application.get_env(:steward, :hot_swap, [])),
      timer_ref: nil,
      last_vantage_pct: nil,
      last_trigger_ms: nil,
      last_trigger_fingerprint: nil
    }

    maybe_subscribe_observability(state)

    {:ok, maybe_schedule_evaluation(state)}
  end

  @impl true
  def handle_info(:evaluate, state) do
    next_state =
      state
      |> Map.put(:timer_ref, nil)
      |> maybe_evaluate(:timer)
      |> maybe_schedule_evaluation()

    {:noreply, next_state}
  end

  def handle_info(%{event: :observability_updated}, state) do
    {:noreply, maybe_evaluate(state, :observability)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp maybe_schedule_evaluation(%{enabled: true, timer_ref: nil} = state) do
    %{state | timer_ref: Process.send_after(self(), :evaluate, state.evaluation_interval_ms)}
  end

  defp maybe_schedule_evaluation(state), do: state

  defp maybe_subscribe_observability(%{enabled: true}) do
    _ = ObservabilityPubSub.subscribe()
    :ok
  rescue
    _ -> :ok
  end

  defp maybe_subscribe_observability(_state), do: :ok

  defp maybe_evaluate(%{enabled: false} = state, _source), do: state

  defp maybe_evaluate(state, source) do
    now_ms = monotonic_ms()

    case fetch_snapshot(state.snapshot_timeout_ms) do
      {:ok, snapshot} ->
        evaluate_from_snapshot(state, snapshot, source, now_ms)

      {:error, reason} ->
        append_automation_event(%{
          event: :automation_evaluation_skipped,
          reason: :snapshot_unavailable,
          source: source,
          detail: inspect(reason)
        })

        state
    end
  end

  defp evaluate_from_snapshot(state, snapshot, source, now_ms) do
    {current_vantage_pct, metric_process_ids} = extract_vantage_pct(snapshot)

    targets =
      case metric_process_ids do
        [] -> fallback_targets(snapshot)
        _ -> metric_process_ids
      end

    evaluation_input = %{
      current_vantage_pct: current_vantage_pct,
      previous_vantage_pct: state.last_vantage_pct,
      vantage_drop_threshold_pct: state.vantage_drop_threshold_pct,
      default_action: state.default_action,
      targets: targets,
      params: %{automation_id: @default_automation_id},
      automation_id: @default_automation_id
    }

    next_state = maybe_set_last_vantage(state, current_vantage_pct)

    case evaluate_snapshot(evaluation_input) do
      :noop ->
        append_automation_event(%{
          event: :automation_evaluated,
          outcome: :noop,
          reason: noop_reason(evaluation_input),
          source: source,
          current_vantage_pct: current_vantage_pct,
          previous_vantage_pct: state.last_vantage_pct
        })

        %{next_state | last_trigger_fingerprint: nil}

      {:trigger, decision} ->
        maybe_trigger(next_state, snapshot, decision, source, now_ms)
    end
  end

  defp maybe_trigger(state, snapshot, decision, source, now_ms) do
    leader_node = leader_node(snapshot, state.leader_mode)

    cond do
      leader_node != node() ->
        append_automation_event(%{
          event: :automation_evaluated,
          outcome: :noop,
          reason: :not_leader,
          source: source,
          leader_node: leader_node,
          local_node: node(),
          decision: decision_summary(decision)
        })

        state

      in_cooldown?(state, now_ms) ->
        append_automation_event(%{
          event: :automation_evaluated,
          outcome: :noop,
          reason: :cooldown_active,
          source: source,
          cooldown_remaining_ms: cooldown_remaining_ms(state, now_ms),
          decision: decision_summary(decision)
        })

        state

      state.last_trigger_fingerprint == decision.fingerprint ->
        append_automation_event(%{
          event: :automation_evaluated,
          outcome: :noop,
          reason: :duplicate_signal,
          source: source,
          decision: decision_summary(decision)
        })

        state

      true ->
        append_automation_event(%{
          event: :automation_trigger_attempted,
          source: source,
          decision: decision_summary(decision)
        })

        context = %{
          automation_id: decision.automation_id,
          trigger_source: decision.trigger_source,
          trigger_reason: decision.trigger_reason,
          params: decision.params
        }

        case trigger_run(decision.action, decision.targets, context) do
          {:ok, run} ->
            append_automation_event(%{
              event: :automation_triggered,
              source: source,
              run_id: run.run_id,
              action: run.action,
              targets: run.targets,
              trigger_reason: run.trigger_reason
            })

            %{
              state
              | last_trigger_ms: now_ms,
                last_trigger_fingerprint: decision.fingerprint
            }

          {:error, reason} ->
            append_automation_event(%{
              event: :automation_trigger_failed,
              source: source,
              reason: inspect(reason),
              decision: decision_summary(decision)
            })

            state
        end
    end
  end

  defp fetch_snapshot(timeout_ms) do
    if Process.whereis(StatusStore) do
      {:ok, StatusStore.snapshot(timeout_ms)}
    else
      {:error, :status_store_not_available}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp extract_vantage_pct(snapshot) do
    processes = Map.get(snapshot, :processes, %{})

    {pairs, metric_targets} =
      Enum.reduce(processes, {[], []}, fn {process_id, process_snapshot},
                                          {acc_pairs, acc_targets} ->
        case extract_process_vantage_pct(process_snapshot) do
          {:ok, value} -> {[value | acc_pairs], [process_id | acc_targets]}
          :error -> {acc_pairs, acc_targets}
        end
      end)

    case pairs do
      [] ->
        {nil, []}

      values ->
        avg = Enum.sum(values) / length(values)
        {Float.round(avg, 2), Enum.reverse(metric_targets)}
    end
  end

  defp extract_process_vantage_pct(snapshot) when is_map(snapshot) do
    metrics =
      cond do
        is_map(Map.get(snapshot, :metrics)) -> Map.get(snapshot, :metrics)
        is_map(Map.get(snapshot, "metrics")) -> Map.get(snapshot, "metrics")
        true -> %{}
      end

    with nil <- metric_value(metrics),
         nil <- metric_value(snapshot) do
      :error
    else
      value -> normalize_percentage(value)
    end
  end

  defp extract_process_vantage_pct(_snapshot), do: :error

  defp metric_value(map) when is_map(map) do
    Enum.find_value(@vantage_metric_keys, &Map.get(map, &1))
  end

  defp fallback_targets(snapshot) do
    from_membership =
      snapshot
      |> Map.get(:membership, %{})
      |> Map.get(:processes_by_node, %{})
      |> Enum.flat_map(fn
        {_node_id, %MapSet{} = process_ids} -> MapSet.to_list(process_ids)
        _ -> []
      end)

    from_processes =
      snapshot
      |> Map.get(:processes, %{})
      |> Map.keys()

    (from_membership ++ from_processes)
    |> normalize_targets()
  end

  defp leader_node(snapshot, :lowest_node) do
    up_nodes =
      snapshot
      |> Map.get(:membership, %{})
      |> Map.get(:nodes, %{})
      |> Enum.reduce([], fn
        {node_id, status}, acc when is_atom(node_id) and status in [:up, "up"] ->
          [node_id | acc]

        _, acc ->
          acc
      end)

    case up_nodes do
      [] -> node()
      nodes -> Enum.min_by(nodes, &Atom.to_string/1)
    end
  end

  defp leader_node(_snapshot, _leader_mode), do: node()

  defp in_cooldown?(%{last_trigger_ms: nil}, _now_ms), do: false

  defp in_cooldown?(%{last_trigger_ms: last_trigger_ms, cooldown_ms: cooldown_ms}, now_ms) do
    now_ms - last_trigger_ms < cooldown_ms
  end

  defp cooldown_remaining_ms(%{last_trigger_ms: nil}, _now_ms), do: 0

  defp cooldown_remaining_ms(
         %{last_trigger_ms: last_trigger_ms, cooldown_ms: cooldown_ms},
         now_ms
       ) do
    max(cooldown_ms - (now_ms - last_trigger_ms), 0)
  end

  defp noop_reason(input) do
    cond do
      is_nil(input.current_vantage_pct) -> :insufficient_signal
      is_nil(input.previous_vantage_pct) -> :insufficient_history
      input.previous_vantage_pct <= 0.0 -> :insufficient_history
      input.targets == [] -> :no_targets
      true -> :below_threshold
    end
  end

  defp decision_summary(decision) do
    %{
      automation_id: decision.automation_id,
      action: decision.action,
      targets: decision.targets,
      fingerprint: decision.fingerprint,
      trigger_reason: decision.trigger_reason
    }
  end

  defp maybe_set_last_vantage(state, nil), do: state

  defp maybe_set_last_vantage(state, current_vantage_pct),
    do: %{state | last_vantage_pct: current_vantage_pct}

  defp ensure_known_action(action) do
    if Actions.known_action?(action), do: :ok, else: {:error, :invalid_action}
  end

  defp normalize_non_empty_targets(targets) do
    normalized = normalize_targets(targets)
    if normalized == [], do: {:error, :invalid_targets}, else: {:ok, normalized}
  end

  defp normalize_targets(targets) when is_list(targets) do
    targets
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_targets(_targets), do: []

  defp normalize_action(action) do
    case Actions.parse_action(action || @default_action) do
      {:ok, normalized_action} -> normalized_action
      {:error, :invalid_action} -> @default_action
    end
  end

  defp build_run_attrs(action, targets, context) do
    run_id = "auto_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    trigger_source = normalize_trigger_source(Map.get(context, :trigger_source))
    trigger_reason = normalize_trigger_reason(Map.get(context, :trigger_reason))
    automation_id = Map.get(context, :automation_id, @default_automation_id)

    params =
      normalize_params(Map.get(context, :params, %{}))
      |> Map.put_new(:automation_id, automation_id)

    attrs = %{
      run_id: run_id,
      action: action,
      targets: targets,
      params: params,
      trigger_source: trigger_source,
      trigger_reason: trigger_reason
    }

    {:ok, attrs}
  end

  defp normalize_trigger_source(source)
       when source in [:manual, :metric, :trace, :operator],
       do: source

  defp normalize_trigger_source(_source), do: :metric

  defp normalize_trigger_reason(reason) when is_binary(reason), do: reason
  defp normalize_trigger_reason(reason) when is_map(reason), do: reason
  defp normalize_trigger_reason(_reason), do: %{}

  defp normalize_params(params) when is_map(params), do: params
  defp normalize_params(_params), do: %{}

  defp append_automation_event(event) when is_map(event) do
    _ =
      StatusStore.append_event(
        event
        |> Map.put_new(:entity, :automation)
        |> Map.put_new(:automation_id, @default_automation_id)
      )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp vantage_drop_pct(previous_vantage_pct, current_vantage_pct) do
    ((previous_vantage_pct - current_vantage_pct) / previous_vantage_pct * 100.0)
    |> max(0.0)
    |> Float.round(2)
  end

  defp normalize_percentage(value) when is_integer(value), do: normalize_percentage(value * 1.0)

  defp normalize_percentage(value) when is_float(value) and value >= 0.0 and value <= 1.0,
    do: {:ok, Float.round(value * 100.0, 2)}

  defp normalize_percentage(value) when is_float(value) and value <= 100.0,
    do: {:ok, Float.round(value, 2)}

  defp normalize_percentage(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> normalize_percentage(float)
      _ -> :error
    end
  end

  defp normalize_percentage(_value), do: :error

  defp fetch_number(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_integer(value) ->
        value * 1.0

      value when is_float(value) ->
        value

      value when is_binary(value) ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fetch_binary(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(_value), do: @default_vantage_drop_threshold_pct

  defp fingerprint_for(trigger_reason, targets) do
    hash =
      :erlang.phash2(
        {
          trigger_reason[:signal],
          trigger_reason[:previous_vantage_pct],
          trigger_reason[:current_vantage_pct],
          trigger_reason[:drop_pct],
          targets
        },
        4_294_967_295
      )

    "vantage_drop:" <> Integer.to_string(hash)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
