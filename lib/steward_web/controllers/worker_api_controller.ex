defmodule StewardWeb.WorkerAPIController do
  @moduledoc false
  use StewardWeb, :controller

  alias Steward.{StatusStore, WorkerSupervisor}

  def upgrade(conn, %{"process_id" => process_id} = params) do
    with {:ok, binary_path} <- fetch_binary_path(params),
         {:ok, args} <- fetch_args(params),
         {:ok, opts} <- fetch_opts(params),
         :ok <- WorkerSupervisor.upgrade_worker(process_id, binary_path, args, opts) do
      conn
      |> put_status(:accepted)
      |> json(%{ok: true, process_id: process_id})
    else
      {:error, :invalid_binary_path} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_binary_path"})

      {:error, :invalid_args} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_args"})

      {:error, :invalid_opts} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_opts"})

      {:error, :invalid_readiness_mode} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_readiness_mode"})

      {:error, :invalid_timeout} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_timeout"})

      {:error, :upgrade_in_progress} ->
        conn |> put_status(:conflict) |> json(%{error: "upgrade_in_progress"})

      {:error, :unsupported_transport} ->
        conn |> put_status(:conflict) |> json(%{error: "unsupported_transport"})

      {:error, :hot_swap_disabled} ->
        conn |> put_status(:conflict) |> json(%{error: "hot_swap_disabled"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def show(conn, %{"process_id" => process_id}) do
    case StatusStore.get_process_snapshot(process_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      snapshot ->
        json(conn, %{process_id: process_id, snapshot: snapshot})
    end
  end

  defp fetch_binary_path(params) do
    case Map.get(params, "binary_path") || Map.get(params, :binary_path) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_binary_path}
    end
  end

  defp fetch_args(params) do
    case Map.get(params, "args") || Map.get(params, :args) do
      nil ->
        {:ok, []}

      args when is_list(args) ->
        if Enum.all?(args, &is_binary/1), do: {:ok, args}, else: {:error, :invalid_args}

      _ ->
        {:error, :invalid_args}
    end
  end

  defp fetch_opts(params) do
    raw_opts = Map.get(params, "opts") || Map.get(params, :opts) || %{}

    if is_map(raw_opts) do
      opts =
        []
        |> maybe_put_opt(
          :readiness_mode,
          Map.get(raw_opts, "readiness_mode") || Map.get(raw_opts, :readiness_mode)
        )
        |> maybe_put_opt(
          :readiness_timeout_ms,
          Map.get(raw_opts, "readiness_timeout_ms") || Map.get(raw_opts, :readiness_timeout_ms)
        )
        |> maybe_put_opt(
          :graceful_shutdown_timeout_ms,
          Map.get(raw_opts, "graceful_shutdown_timeout_ms") ||
            Map.get(raw_opts, :graceful_shutdown_timeout_ms)
        )

      {:ok, opts}
    else
      {:error, :invalid_opts}
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
