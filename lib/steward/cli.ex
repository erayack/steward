defmodule Steward.CLI do
  @moduledoc "CLI parser and command normalization for operator-facing workflows."

  alias Steward.Actions

  @type command ::
          {:start,
           %{
             optional(:port) => pos_integer() | nil,
             optional(:server_enabled) => boolean()
           }}
          | {:run,
             %{
               required(:run_id) => String.t(),
               required(:action) => atom(),
               required(:targets) => [String.t()],
               required(:params) => map(),
               optional(:desired_config_version) => String.t() | nil
             }}
          | {:workers, :list}
          | {:workers,
             {:upgrade,
              %{
                required(:process_id) => String.t(),
                required(:binary_path) => String.t(),
                required(:args) => [String.t()],
                required(:opts) => keyword()
              }}}

  @spec parse([String.t()]) :: {:ok, command()} | {:error, term()}
  def parse(["start" | args]), do: parse_start(args)
  def parse(["run" | args]), do: parse_run(args)
  def parse(["workers", "list"]), do: {:ok, {:workers, :list}}
  def parse(["workers", "upgrade" | args]), do: parse_workers_upgrade(args)
  def parse(["workers" | _]), do: {:error, :invalid_workers_command}
  def parse(_), do: {:error, :invalid_command}

  defp parse_start(args) do
    switches = [port: :integer]

    with {:ok, opts} <- parse_options(args, switches),
         :ok <- ensure_no_args(opts),
         {:ok, port} <- normalize_port(Keyword.get(opts.options, :port)) do
      {:ok,
       {:start,
        %{
          port: port,
          server_enabled: true
        }}}
    end
  end

  defp parse_run(args) do
    switches = [
      action: :string,
      targets: :string,
      params: :string,
      "run-id": :string,
      "desired-config-version": :string
    ]

    with {:ok, opts} <- parse_options(args, switches),
         :ok <- ensure_no_args(opts),
         {:ok, action} <- parse_action(Keyword.get(opts.options, :action)),
         {:ok, targets} <- parse_targets(Keyword.get(opts.options, :targets)),
         {:ok, params} <- parse_params(Keyword.get(opts.options, :params)),
         {:ok, run_id} <- parse_run_id(Keyword.get(opts.options, :"run-id")) do
      {:ok,
       {:run,
        %{
          run_id: run_id,
          action: action,
          targets: targets,
          params: params,
          desired_config_version: Keyword.get(opts.options, :"desired-config-version")
        }}}
    end
  end

  defp parse_workers_upgrade(args) do
    switches = [
      "process-id": :string,
      "binary-path": :string,
      args: :string,
      "readiness-mode": :string,
      "readiness-timeout-ms": :integer,
      "graceful-shutdown-timeout-ms": :integer
    ]

    with {:ok, opts} <- parse_options(args, switches),
         :ok <- ensure_no_args(opts),
         {:ok, process_id} <- parse_process_id(Keyword.get(opts.options, :"process-id")),
         {:ok, binary_path} <- parse_binary_path(Keyword.get(opts.options, :"binary-path")),
         {:ok, normalized_args} <- parse_worker_args(Keyword.get(opts.options, :args)),
         {:ok, normalized_opts} <- parse_upgrade_opts(opts.options) do
      {:ok,
       {:workers,
        {:upgrade,
         %{
           process_id: process_id,
           binary_path: binary_path,
           args: normalized_args,
           opts: normalized_opts
         }}}}
    end
  end

  defp parse_options(args, switches) do
    {options, remaining, invalid} = OptionParser.parse(args, strict: switches)

    if invalid != [] do
      {:error, {:invalid_option, invalid}}
    else
      {:ok, %{options: options, remaining: remaining}}
    end
  end

  defp ensure_no_args(%{remaining: []}), do: :ok
  defp ensure_no_args(%{remaining: remaining}), do: {:error, {:unexpected_arguments, remaining}}

  defp normalize_port(nil), do: {:ok, nil}

  defp normalize_port(port) when is_integer(port) and port in 1..65_535,
    do: {:ok, port}

  defp normalize_port(_), do: {:error, :invalid_port}

  defp parse_action(nil), do: {:error, :missing_action}

  defp parse_action(action) do
    case Actions.parse_action(action) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, :invalid_action} -> {:error, :invalid_action}
    end
  end

  defp parse_targets(nil), do: {:error, :missing_targets}

  defp parse_targets(targets_csv) when is_binary(targets_csv) do
    targets =
      targets_csv
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if targets == [] do
      {:error, :invalid_targets}
    else
      {:ok, targets}
    end
  end

  defp parse_targets(_), do: {:error, :invalid_targets}

  defp parse_params(nil), do: {:ok, %{}}

  defp parse_params(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, params} when is_map(params) -> {:ok, params}
      {:ok, _other} -> {:error, :invalid_params}
      {:error, _reason} -> {:error, :invalid_params_json}
    end
  end

  defp parse_params(_), do: {:error, :invalid_params}

  defp parse_run_id(nil), do: {:ok, generate_run_id()}

  defp parse_run_id(run_id) when is_binary(run_id) and run_id != "", do: {:ok, run_id}
  defp parse_run_id(_), do: {:error, :invalid_run_id}

  defp parse_process_id(process_id) when is_binary(process_id) and process_id != "",
    do: {:ok, process_id}

  defp parse_process_id(_), do: {:error, :invalid_process_id}

  defp parse_binary_path(path) when is_binary(path) and path != "", do: {:ok, path}
  defp parse_binary_path(_), do: {:error, :invalid_binary_path}

  defp parse_worker_args(nil), do: {:ok, []}

  defp parse_worker_args(args_csv) when is_binary(args_csv) do
    args =
      args_csv
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, args}
  end

  defp parse_worker_args(_), do: {:error, :invalid_args}

  defp parse_upgrade_opts(options) do
    with {:ok, readiness_mode} <- parse_readiness_mode(Keyword.get(options, :"readiness-mode")),
         {:ok, readiness_timeout_ms} <-
           parse_timeout_ms(Keyword.get(options, :"readiness-timeout-ms"), :readiness_timeout_ms),
         {:ok, graceful_shutdown_timeout_ms} <-
           parse_timeout_ms(
             Keyword.get(options, :"graceful-shutdown-timeout-ms"),
             :graceful_shutdown_timeout_ms
           ) do
      opts =
        []
        |> maybe_put_keyword(:readiness_mode, readiness_mode)
        |> maybe_put_keyword(:readiness_timeout_ms, readiness_timeout_ms)
        |> maybe_put_keyword(:graceful_shutdown_timeout_ms, graceful_shutdown_timeout_ms)

      {:ok, opts}
    end
  end

  defp parse_readiness_mode(nil), do: {:ok, nil}
  defp parse_readiness_mode("port_open"), do: {:ok, :port_open}
  defp parse_readiness_mode("heartbeat"), do: {:ok, :heartbeat}
  defp parse_readiness_mode(_), do: {:error, :invalid_readiness_mode}

  defp parse_timeout_ms(nil, _field), do: {:ok, nil}
  defp parse_timeout_ms(value, _field) when is_integer(value) and value > 0, do: {:ok, value}
  defp parse_timeout_ms(_value, field), do: {:error, {:invalid_field, field}}

  defp maybe_put_keyword(keyword, _key, nil), do: keyword
  defp maybe_put_keyword(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp generate_run_id do
    "run_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
