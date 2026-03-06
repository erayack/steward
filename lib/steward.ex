defmodule Steward do
  @moduledoc "Steward composition root and CLI command dispatcher."

  alias Steward.{CLI, RunExecutor, RunRegistry, WorkerSupervisor}

  @type started_apps :: [atom()]

  @spec main([String.t()]) :: no_return()
  @dialyzer {:nowarn_function, main: 0}
  def main(argv \\ System.argv()) do
    case execute_cli(argv) do
      :ok ->
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "error: #{format_error(reason)}")
        System.halt(1)
    end
  end

  @spec execute_cli([String.t()]) :: :ok | {:error, term()}
  def execute_cli(argv) when is_list(argv) do
    with {:ok, command} <- CLI.parse(argv) do
      dispatch(command)
    end
  end

  @spec start_runtime(keyword()) :: {:ok, started_apps()} | {:error, term()}
  def start_runtime(opts \\ []) do
    apply_runtime_overrides(opts)
    Application.ensure_all_started(:steward)
  end

  @spec stop_runtime(started_apps()) :: :ok
  def stop_runtime(started_apps) when is_list(started_apps) do
    started_apps
    |> Enum.reverse()
    |> Enum.each(fn app ->
      _ = Application.stop(app)
    end)

    :ok
  end

  @spec trigger_run(map()) :: {:ok, Steward.Types.Run.t()} | {:error, term()}
  def trigger_run(attrs) when is_map(attrs) do
    with {:ok, run} <- RunRegistry.create_run(attrs) do
      RunExecutor.execute(run)
    end
  end

  @spec list_workers() :: {:ok, [map()]}
  def list_workers do
    {:ok, WorkerSupervisor.list_workers()}
  end

  defp dispatch({:start, start_opts}) do
    with {:ok, _started_apps} <- start_runtime(overrides: start_overrides(start_opts)) do
      print_start_banner(start_opts)
      Process.sleep(:infinity)
    end
  end

  defp dispatch({:run, run_attrs}) do
    with {:ok, started_apps} <- start_runtime(overrides: one_shot_overrides()) do
      try do
        with {:ok, executed_run} <- trigger_run(run_attrs) do
          print_run_result(executed_run)
          :ok
        end
      after
        stop_runtime(started_apps)
      end
    end
  end

  defp dispatch({:workers, :list}) do
    with {:ok, started_apps} <- start_runtime(overrides: one_shot_overrides()) do
      try do
        with {:ok, workers} <- list_workers() do
          print_workers(workers)
          :ok
        end
      after
        stop_runtime(started_apps)
      end
    end
  end

  defp start_overrides(start_opts) do
    server =
      [enabled: Map.get(start_opts, :server_enabled, true)]
      |> maybe_put(:port, Map.get(start_opts, :port))

    [server: server]
  end

  defp one_shot_overrides do
    [server: [enabled: false]]
  end

  defp apply_runtime_overrides(opts) do
    overrides = Keyword.get(opts, :overrides, [])

    if server = Keyword.get(overrides, :server) do
      current = Application.get_env(:steward, :server, [])
      Application.put_env(:steward, :server, Keyword.merge(current, server))
    end
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp print_start_banner(start_opts) do
    port =
      case Map.get(start_opts, :port) do
        nil -> Application.get_env(:steward, :server, []) |> Keyword.get(:port, 4000)
        explicit_port -> explicit_port
      end

    IO.puts("steward started")
    IO.puts("observability: http://127.0.0.1:#{port}")
  end

  defp print_run_result(run) do
    IO.puts("run_id: #{run.run_id}")
    IO.puts("action: #{run.action}")
    IO.puts("status: #{run.status}")

    Enum.each(run.results, fn {target, result} ->
      IO.puts("#{target}: #{inspect(result)}")
    end)
  end

  defp print_workers(workers) do
    if workers == [] do
      IO.puts("no workers")
    else
      Enum.each(workers, fn %{process_id: process_id, pid: pid} ->
        IO.puts("#{process_id}\t#{inspect(pid)}")
      end)
    end
  end

  defp format_error({:invalid_option, invalid}), do: "invalid option #{inspect(invalid)}"
  defp format_error({:unexpected_arguments, args}), do: "unexpected args #{inspect(args)}"
  defp format_error(reason), do: inspect(reason)
end
