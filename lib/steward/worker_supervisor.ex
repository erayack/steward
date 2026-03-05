defmodule Steward.WorkerSupervisor do
  @moduledoc "Control plane for dynamically managed process workers."
  use GenServer

  require Logger

  alias Steward.Types

  @worker_registry Steward.WorkerRegistry
  @worker_dynamic_supervisor Steward.WorkerDynamicSupervisor
  @bootstrap_process_id "mock_agent"

  @type worker_ref :: %{process_id: Types.process_id(), pid: pid()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec ensure_worker(Types.process_id(), Path.t(), [String.t()]) ::
          {:ok, pid()} | {:error, term()}
  def ensure_worker(process_id, binary_path, args \\ [])
      when is_binary(process_id) and process_id != "" and is_binary(binary_path) and is_list(args) do
    GenServer.call(__MODULE__, {:ensure_worker, process_id, binary_path, args})
  end

  @spec terminate_worker(Types.process_id()) :: :ok | {:error, term()}
  def terminate_worker(process_id) when is_binary(process_id) and process_id != "" do
    GenServer.call(__MODULE__, {:terminate_worker, process_id})
  end

  @spec list_workers() :: [worker_ref()]
  def list_workers do
    GenServer.call(__MODULE__, :list_workers)
  end

  @impl true
  def init(opts) do
    state = %{
      registry: Keyword.get(opts, :registry, @worker_registry),
      dynamic_supervisor: Keyword.get(opts, :dynamic_supervisor, @worker_dynamic_supervisor),
      bootstrap?: Keyword.get(opts, :bootstrap?, true)
    }

    if state.bootstrap?, do: send(self(), :bootstrap_workers)
    {:ok, state}
  end

  @impl true
  def handle_call({:ensure_worker, process_id, binary_path, args}, _from, state) do
    result =
      cond do
        not valid_process_id?(process_id) ->
          {:error, :invalid_process_id}

        not is_binary(binary_path) or binary_path == "" ->
          {:error, :invalid_binary_path}

        not valid_args?(args) ->
          {:error, :invalid_args}

        true ->
          do_ensure_worker(process_id, binary_path, args, state)
      end

    {:reply, result, state}
  end

  def handle_call({:terminate_worker, process_id}, _from, state) do
    result =
      case lookup_worker_pid(process_id, state.registry) do
        {:ok, pid} ->
          case DynamicSupervisor.terminate_child(state.dynamic_supervisor, pid) do
            :ok -> :ok
            {:error, :not_found} -> :ok
          end

        :error ->
          :ok
      end

    {:reply, result, state}
  end

  def handle_call(:list_workers, _from, state) do
    {:reply, list_worker_refs(state.registry), state}
  end

  @impl true
  def handle_info(:bootstrap_workers, state) do
    bootstrap_specs()
    |> Enum.each(fn %{process_id: process_id, binary_path: binary_path, args: args} ->
      case do_ensure_worker(process_id, binary_path, args, state) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.error("failed to bootstrap worker #{process_id}: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp do_ensure_worker(process_id, binary_path, args, state) do
    case lookup_worker_pid(process_id, state.registry) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        DynamicSupervisor.start_child(
          state.dynamic_supervisor,
          worker_child_spec(process_id, binary_path, args, state.registry)
        )
        |> normalize_start_result(process_id, state.registry)
    end
  end

  defp normalize_start_result({:ok, pid}, _process_id, _registry), do: {:ok, pid}

  defp normalize_start_result({:ok, pid, _info}, _process_id, _registry), do: {:ok, pid}

  defp normalize_start_result(:ignore, _process_id, _registry), do: {:error, :ignored}

  defp normalize_start_result({:error, {:already_started, pid}}, _process_id, _registry),
    do: {:ok, pid}

  defp normalize_start_result({:error, :already_present}, process_id, registry) do
    case lookup_worker_pid(process_id, registry) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, :already_present}
    end
  end

  defp normalize_start_result({:error, reason}, _process_id, _registry), do: {:error, reason}

  defp worker_child_spec(process_id, binary_path, args, registry) do
    %{
      id: {:port_worker, process_id},
      start:
        {Steward.PortWorker, :start_link,
         [
           [
             name: {:via, Registry, {registry, process_id}},
             process_id: process_id,
             binary_path: binary_path,
             args: args
           ]
         ]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  defp lookup_worker_pid(process_id, registry) do
    case Registry.lookup(registry, process_id) do
      [{pid, _value}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: :error

      _ ->
        :error
    end
  end

  defp list_worker_refs(registry) do
    registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_process_id, pid} -> is_pid(pid) and Process.alive?(pid) end)
    |> Enum.map(fn {process_id, pid} -> %{process_id: process_id, pid: pid} end)
    |> Enum.sort_by(& &1.process_id)
  end

  @doc false
  def bootstrap_specs do
    case Application.get_env(:steward, :workers, []) do
      workers when is_list(workers) and workers != [] ->
        workers
        |> Enum.flat_map(&normalize_worker_spec/1)
        |> Enum.uniq_by(& &1.process_id)

      _ ->
        mock_agent_bootstrap_spec()
    end
  end

  @doc false
  def normalize_worker_spec(%{} = worker) do
    process_id = Map.get(worker, :process_id) || Map.get(worker, "process_id")
    binary_path = Map.get(worker, :binary_path) || Map.get(worker, "binary_path")
    args = Map.get(worker, :args) || Map.get(worker, "args") || []

    if valid_process_id?(process_id) and is_binary(binary_path) and valid_args?(args) do
      [%{process_id: process_id, binary_path: binary_path, args: args}]
    else
      Logger.warning("skipping invalid worker bootstrap entry: #{inspect(worker)}")
      []
    end
  end

  def normalize_worker_spec(other) do
    Logger.warning("skipping non-map worker bootstrap entry: #{inspect(other)}")
    []
  end

  defp mock_agent_bootstrap_spec do
    mock_agent_cfg = Application.get_env(:steward, :mock_agent, [])
    mock_agent_path = Keyword.get(mock_agent_cfg, :path)
    mock_agent_args = Keyword.get(mock_agent_cfg, :args, [])

    if is_binary(mock_agent_path) and valid_args?(mock_agent_args) and
         File.exists?(mock_agent_path) do
      [
        %{
          process_id: @bootstrap_process_id,
          binary_path: mock_agent_path,
          args: mock_agent_args
        }
      ]
    else
      if is_binary(mock_agent_path) and mock_agent_path != "" and
           not File.exists?(mock_agent_path) do
        Logger.warning(
          "mock agent binary not found, skipping bootstrap: #{inspect(mock_agent_path)}"
        )
      end

      []
    end
  end

  @doc false
  def valid_process_id?(value), do: is_binary(value) and value != ""

  @doc false
  def valid_args?(args), do: is_list(args) and Enum.all?(args, &is_binary/1)
end
