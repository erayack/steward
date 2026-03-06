defmodule Steward.Application do
  @moduledoc false
  use Application
  @dialyzer {:nowarn_function, base_children: 0, maybe_http_server: 1}

  @impl true
  def start(_type, _args) do
    children = base_children() ++ maybe_http_server(server_config())

    opts = [strategy: :one_for_one, name: Steward.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @spec base_children() :: [Supervisor.child()]
  def base_children do
    [
      {Phoenix.PubSub, name: Steward.PubSub},
      {Task.Supervisor, name: Steward.TaskSupervisor},
      Steward.ClusterMembership,
      {Registry, keys: :unique, name: Steward.WorkerRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Steward.WorkerDynamicSupervisor},
      Steward.WorkerSupervisor,
      Steward.RunRegistry,
      Steward.StatusStore
    ]
  end

  @spec maybe_http_server(keyword()) :: [Supervisor.child()]
  def maybe_http_server(server_config) when is_list(server_config) do
    if Keyword.get(server_config, :enabled, false) do
      [StewardWeb.Endpoint, Steward.HttpServer]
    else
      []
    end
  end

  @spec server_config() :: keyword()
  def server_config do
    Application.get_env(:steward, :server, [])
  end
end
