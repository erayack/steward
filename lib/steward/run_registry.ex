defmodule Steward.RunRegistry do
  @moduledoc "In-memory run and idempotency registry."
  use GenServer

  alias Steward.{Run, StatusStore}
  alias Steward.Types

  @type server :: GenServer.server()
  @type applied_ids_by_node :: %{optional(node()) => MapSet.t(Types.run_id())}
  @type state :: %{
          active_runs: %{optional(Types.run_id()) => Types.run()},
          completed_runs: %{optional(Types.run_id()) => Types.run_summary()},
          completed_order: :queue.queue(Types.run_id()),
          applied_run_ids_by_node: applied_ids_by_node(),
          applied_meta_by_node: %{optional(node()) => %{optional(Types.run_id()) => integer()}},
          opts: %{
            idempotency_ttl_ms: :infinity | pos_integer(),
            idempotency_max_ids_per_node: :infinity | pos_integer(),
            completed_runs_max: :infinity | pos_integer()
          }
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec create_run(map()) :: {:ok, Types.Run.t()} | {:error, term()}
  def create_run(attrs), do: create_run(__MODULE__, attrs)

  @spec create_run(server(), map()) :: {:ok, Types.Run.t()} | {:error, term()}
  def create_run(server, attrs) when is_map(attrs) do
    GenServer.call(server, {:create_run, attrs})
  end

  @spec mark_running(Types.run_id()) :: :ok
  def mark_running(run_id), do: mark_running(__MODULE__, run_id)

  @spec mark_running(server(), Types.run_id()) :: :ok
  def mark_running(server, run_id) when is_binary(run_id) and run_id != "" do
    GenServer.call(server, {:mark_running, run_id})
  end

  @spec apply_once(node(), Types.run_id()) :: :applied | :already_applied
  def apply_once(node_id, run_id), do: apply_once(__MODULE__, node_id, run_id)

  @spec apply_once(server(), node(), Types.run_id()) :: :applied | :already_applied
  def apply_once(server, node_id, run_id)
      when is_atom(node_id) and is_binary(run_id) and run_id != "" do
    GenServer.call(server, {:apply_once, node_id, run_id})
  end

  @spec complete_run(Types.run_id(), map()) :: :ok
  def complete_run(run_id, completion), do: complete_run(__MODULE__, run_id, completion)

  @spec complete_run(server(), Types.run_id(), map()) :: :ok
  def complete_run(server, run_id, completion)
      when is_binary(run_id) and run_id != "" and is_map(completion) do
    GenServer.call(server, {:complete_run, run_id, completion})
  end

  @spec snapshot() :: map()
  def snapshot, do: snapshot(__MODULE__)

  @spec snapshot(server()) :: map()
  def snapshot(server) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    run_cfg = Application.get_env(:steward, :run, [])

    state = %{
      active_runs: %{},
      completed_runs: %{},
      completed_order: :queue.new(),
      applied_run_ids_by_node: %{},
      applied_meta_by_node: %{},
      opts: %{
        idempotency_ttl_ms: read_bound_opt(opts, run_cfg, :idempotency_ttl_ms, :infinity),
        idempotency_max_ids_per_node:
          read_bound_opt(opts, run_cfg, :idempotency_max_ids_per_node, :infinity),
        completed_runs_max: read_bound_opt(opts, run_cfg, :completed_runs_max, :infinity)
      }
    }

    publish_runs_if_available(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:create_run, attrs}, _from, state) do
    with {:ok, run} <- Run.new(attrs),
         false <- duplicate_run_id?(state, run.run_id) do
      next_state = put_in(state.active_runs[run.run_id], run)
      publish_runs_if_available(next_state)
      {:reply, {:ok, run}, next_state}
    else
      true -> {:reply, {:error, :duplicate_run_id}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:mark_running, run_id}, _from, state) do
    {next_state, event_run} =
      case Map.get(state.active_runs, run_id) do
        nil ->
          {state, nil}

        run ->
          case Run.mark_running(run) do
            {:ok, next_run} -> {put_in(state.active_runs[run_id], next_run), next_run}
            {:error, :invalid_transition} -> {state, nil}
          end
      end

    append_audit_event_if_available(run_started_event(event_run))
    maybe_refresh_runs(state, next_state)
    {:reply, :ok, next_state}
  end

  def handle_call({:apply_once, node_id, run_id}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    pruned_state = prune_node_history(state, node_id, now_ms)

    node_ids = Map.get(pruned_state.applied_run_ids_by_node, node_id, MapSet.new())

    if MapSet.member?(node_ids, run_id) do
      {:reply, :already_applied, pruned_state}
    else
      next_node_ids = MapSet.put(node_ids, run_id)

      next_node_meta =
        Map.put(Map.get(pruned_state.applied_meta_by_node, node_id, %{}), run_id, now_ms)

      next_state =
        pruned_state
        |> put_in([:applied_run_ids_by_node, node_id], next_node_ids)
        |> put_in([:applied_meta_by_node, node_id], next_node_meta)
        |> cap_node_history(node_id)

      publish_runs_if_available(next_state)
      {:reply, :applied, next_state}
    end
  end

  def handle_call({:complete_run, run_id, completion}, _from, state) do
    case Map.get(state.active_runs, run_id) do
      nil ->
        {:reply, :ok, state}

      run ->
        case Run.complete(run, completion) do
          {:ok, done_run} ->
            summary = to_summary(done_run, completion)

            next_state =
              state
              |> update_in([:active_runs], &Map.delete(&1, run_id))
              |> put_in([:completed_runs, run_id], summary)
              |> update_in([:completed_order], &:queue.in(run_id, &1))
              |> cap_completed_runs()

            append_audit_event_if_available(run_finished_event(done_run))
            append_target_outcome_events_if_available(done_run.run_id, completion)
            publish_runs_if_available(next_state)
            {:reply, :ok, next_state}

          {:error, :invalid_transition} ->
            {:reply, :ok, state}
        end
    end
  end

  def handle_call(:snapshot, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    pruned_state = prune_all_node_histories(state, now_ms)
    payload = snapshot_payload(pruned_state)
    {:reply, payload, pruned_state}
  end

  defp maybe_refresh_runs(old_state, new_state) do
    if old_state != new_state do
      publish_runs_if_available(new_state)
    end
  end

  defp publish_runs_if_available(state) do
    if Process.whereis(Steward.StatusStore) do
      Steward.StatusStore.refresh_runs(snapshot_payload(state))
    end
  end

  defp snapshot_payload(state) do
    %{
      active_runs: state.active_runs,
      completed_runs: state.completed_runs,
      applied_run_ids: state.applied_run_ids_by_node,
      counts: %{
        active_runs: map_size(state.active_runs),
        completed_runs: map_size(state.completed_runs),
        applied_run_ids_by_node:
          Map.new(state.applied_run_ids_by_node, fn {node_id, ids} ->
            {node_id, MapSet.size(ids)}
          end)
      }
    }
  end

  defp duplicate_run_id?(state, run_id) do
    Map.has_key?(state.active_runs, run_id) or Map.has_key?(state.completed_runs, run_id)
  end

  defp to_summary(run, completion) do
    %{
      run_id: run.run_id,
      action: run.action,
      targets: run.targets,
      status: run.status,
      results: run.results,
      started_at: run.started_at,
      finished_at: run.finished_at,
      trigger_source: run.trigger_source,
      trigger_reason: run.trigger_reason,
      meta: completion
    }
  end

  defp run_started_event(nil), do: nil

  defp run_started_event(run) do
    %{
      entity: :run,
      event: :run_started,
      run_id: run.run_id,
      action: run.action,
      targets: run.targets,
      started_at: run.started_at
    }
  end

  defp run_finished_event(run) do
    %{
      entity: :run,
      event: :run_finished,
      run_id: run.run_id,
      action: run.action,
      started_at: run.started_at,
      finished_at: run.finished_at
    }
  end

  defp append_target_outcome_events_if_available(run_id, completion) do
    Enum.each(completion, fn {target, result} ->
      {outcome, reason} = outcome_and_reason(result)

      append_audit_event_if_available(%{
        entity: :run_target,
        event: :target_outcome,
        run_id: run_id,
        target: target,
        outcome: outcome,
        reason: reason
      })
    end)
  end

  defp outcome_and_reason(value) when is_atom(value), do: {value, nil}
  defp outcome_and_reason({outcome, reason}) when is_atom(outcome), do: {outcome, reason}
  defp outcome_and_reason(other), do: {:unknown, other}

  defp append_audit_event_if_available(nil), do: :ok

  defp append_audit_event_if_available(event) do
    if Process.whereis(StatusStore) do
      _ = StatusStore.append_event(event)
      :ok
    else
      :ok
    end
  end

  defp cap_completed_runs(%{opts: %{completed_runs_max: :infinity}} = state), do: state

  defp cap_completed_runs(state) do
    max = state.opts.completed_runs_max
    overflow = map_size(state.completed_runs) - max
    trim_completed_runs(state, overflow)
  end

  defp trim_completed_runs(state, overflow) when overflow <= 0, do: state

  defp trim_completed_runs(state, overflow) do
    {next_runs, next_order} =
      pop_n_completed(state.completed_runs, state.completed_order, overflow)

    %{state | completed_runs: next_runs, completed_order: next_order}
  end

  defp pop_n_completed(runs, order, 0), do: {runs, order}

  defp pop_n_completed(runs, order, n) do
    case :queue.out(order) do
      {{:value, run_id}, next_order} ->
        pop_n_completed(Map.delete(runs, run_id), next_order, n - 1)

      {:empty, _} ->
        {runs, order}
    end
  end

  defp prune_all_node_histories(state, now_ms) do
    Enum.reduce(Map.keys(state.applied_meta_by_node), state, fn node_id, acc ->
      prune_node_history(acc, node_id, now_ms)
    end)
  end

  defp prune_node_history(state, node_id, now_ms) do
    node_meta = Map.get(state.applied_meta_by_node, node_id, %{})

    next_node_meta =
      case state.opts.idempotency_ttl_ms do
        :infinity ->
          node_meta

        ttl_ms ->
          cutoff = now_ms - ttl_ms

          for {run_id, applied_ms} <- node_meta, applied_ms >= cutoff, into: %{} do
            {run_id, applied_ms}
          end
      end

    next_node_ids = MapSet.new(Map.keys(next_node_meta))

    state
    |> put_in([:applied_meta_by_node, node_id], next_node_meta)
    |> put_in([:applied_run_ids_by_node, node_id], next_node_ids)
  end

  defp cap_node_history(%{opts: %{idempotency_max_ids_per_node: :infinity}} = state, _node_id),
    do: state

  defp cap_node_history(state, node_id) do
    max = state.opts.idempotency_max_ids_per_node
    node_meta = Map.get(state.applied_meta_by_node, node_id, %{})
    overflow = map_size(node_meta) - max

    if overflow <= 0 do
      state
    else
      stale_ids =
        node_meta
        |> Enum.sort_by(fn {_run_id, applied_ms} -> applied_ms end)
        |> Enum.take(overflow)
        |> Enum.map(fn {run_id, _applied_ms} -> run_id end)

      next_node_meta = Map.drop(node_meta, stale_ids)
      next_node_ids = MapSet.new(Map.keys(next_node_meta))

      state
      |> put_in([:applied_meta_by_node, node_id], next_node_meta)
      |> put_in([:applied_run_ids_by_node, node_id], next_node_ids)
    end
  end

  defp read_bound_opt(opts, run_cfg, key, default) do
    opts_value = Keyword.get(opts, key, :missing)
    cfg_value = Keyword.get(run_cfg, key, default)
    value = if opts_value == :missing, do: cfg_value, else: opts_value

    case value do
      :infinity ->
        :infinity

      int when is_integer(int) and int > 0 ->
        int

      _ ->
        default
    end
  end
end
