defmodule Steward.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Phoenix.PubSub, name: Steward.PubSub},
        {Task.Supervisor, name: Steward.TaskSupervisor},
        Steward.ClusterMembership,
        {Registry, keys: :unique, name: Steward.WorkerRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: Steward.WorkerDynamicSupervisor},
        Steward.WorkerSupervisor,
        Steward.RunRegistry,
        Steward.StatusStore
      ] ++ maybe_http_server()

    opts = [strategy: :one_for_one, name: Steward.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_http_server do
    if Application.get_env(:steward, :server, [])[:enabled] do
      [Steward.HttpServer]
    else
      []
    end
  end
end
