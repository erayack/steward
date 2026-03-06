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

  @spec parse([String.t()]) :: {:ok, command()} | {:error, term()}
  def parse(["start" | args]), do: parse_start(args)
  def parse(["run" | args]), do: parse_run(args)
  def parse(["workers", "list"]), do: {:ok, {:workers, :list}}
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

  defp generate_run_id do
    "run_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
