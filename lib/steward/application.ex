defmodule Steward.Application do
  @moduledoc false
  use Application
  @dialyzer {:nowarn_function, base_children: 0, v2_children: 0, maybe_http_server: 1}

  @impl true
  def start(_type, _args) do
    children = base_children() ++ v2_children() ++ maybe_http_server(server_config())

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

  @spec v2_children() :: [Supervisor.child()]
  def v2_children do
    [
      {Steward.TraceIngestor, trace_analysis: trace_analysis_config()},
      {Steward.TraceAnalyzer, trace_analysis: trace_analysis_config()},
      {Steward.SelfHealing.AutomationEngine,
       self_healing: self_healing_config(),
       trace_analysis: trace_analysis_config(),
       hot_swap: hot_swap_config()}
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

  @spec self_healing_config() :: keyword()
  def self_healing_config do
    Application.get_env(:steward, :self_healing, [])
  end

  @spec trace_analysis_config() :: keyword()
  def trace_analysis_config do
    Application.get_env(:steward, :trace_analysis, [])
  end

  @spec hot_swap_config() :: keyword()
  def hot_swap_config do
    Application.get_env(:steward, :hot_swap, [])
  end
end
