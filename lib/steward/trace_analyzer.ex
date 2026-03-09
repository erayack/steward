defmodule Steward.TraceAnalyzer do
  @moduledoc "Analyzes ingested traces and prepares anomaly signals."
  use GenServer

  @type state :: %{
          enabled: boolean(),
          trace_analysis: keyword()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    trace_analysis =
      Keyword.get(opts, :trace_analysis, Application.get_env(:steward, :trace_analysis, []))

    {:ok,
     %{enabled: Keyword.get(trace_analysis, :enabled, false), trace_analysis: trace_analysis}}
  end
end
