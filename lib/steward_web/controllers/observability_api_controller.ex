defmodule StewardWeb.ObservabilityAPIController do
  @moduledoc false
  use StewardWeb, :controller

  alias StewardWeb.Presenter

  def state(conn, _params) do
    json(conn, Presenter.state_payload())
  end

  def run(conn, %{"run_id" => run_id}) do
    case Presenter.run_payload(run_id) do
      {:ok, payload} -> json(conn, payload)
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def trigger_run(conn, params) do
    case Presenter.trigger_run_payload(params) do
      {:ok, payload} ->
        conn |> put_status(:created) |> json(payload)

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end
end
