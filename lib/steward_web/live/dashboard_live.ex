defmodule StewardWeb.DashboardLive do
  @moduledoc false
  use StewardWeb, :live_view

  alias StewardWeb.{ObservabilityPubSub, Presenter}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: ObservabilityPubSub.subscribe()

    payload = Presenter.state_payload()

    {:ok,
     socket
     |> assign(:summary, payload.summary)
     |> assign(:nodes, payload.nodes)
     |> assign(:processes, payload.processes)
     |> assign(:runs, payload.runs)
     |> assign(:updated_at_ms, payload.updated_at_ms)}
  end

  @impl true
  def handle_info(%{event: :observability_updated}, socket) do
    payload = Presenter.state_payload()

    {:noreply,
     socket
     |> assign(:summary, payload.summary)
     |> assign(:nodes, payload.nodes)
     |> assign(:processes, payload.processes)
     |> assign(:runs, payload.runs)
     |> assign(:updated_at_ms, payload.updated_at_ms)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main style="font-family: sans-serif; padding: 1rem; max-width: 1100px; margin: 0 auto;">
      <h1>Steward Dashboard</h1>
      <p>Updated at monotonic ms: <%= @updated_at_ms %></p>

      <section>
        <h2>Summary</h2>
        <p>
          Nodes: <%= @summary.nodes_up %>/<%= @summary.nodes_total %> up |
          Processes: <%= @summary.processes_up %>/<%= @summary.processes_total %> up |
          Active runs: <%= @summary.active_runs %> |
          Completed runs: <%= @summary.completed_runs %>
        </p>
      </section>

      <section>
        <h2>Nodes</h2>
        <div style="display: grid; gap: 0.75rem; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));">
          <article
            :for={node <- @nodes}
            style="border: 1px solid #d8d8d8; border-radius: 8px; padding: 0.75rem; background: #fafafa;"
          >
            <strong><%= node.node %></strong>
            <p>Status: <%= String.upcase(node.status) %></p>
            <p>Processes: <%= node.process_count %></p>
          </article>
        </div>
      </section>

      <section>
        <h2>Processes</h2>
        <table style="width: 100%; border-collapse: collapse;">
          <thead>
            <tr>
              <th style="text-align: left; border-bottom: 1px solid #ddd;">Process</th>
              <th style="text-align: left; border-bottom: 1px solid #ddd;">Status</th>
              <th style="text-align: left; border-bottom: 1px solid #ddd;">Heartbeat Age (ms)</th>
              <th style="text-align: left; border-bottom: 1px solid #ddd;">Restarts</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={proc <- @processes}>
              <td style="padding: 0.35rem 0;"><%= proc.process_id %></td>
              <td style="padding: 0.35rem 0;"><%= String.upcase(proc.status) %></td>
              <td style="padding: 0.35rem 0;"><%= proc.heartbeat_age_ms || "n/a" %></td>
              <td style="padding: 0.35rem 0;"><%= proc.restart_count %></td>
            </tr>
          </tbody>
        </table>
      </section>

      <section>
        <h2>Runs</h2>
        <ul>
          <li :for={run <- @runs}>
            <code><%= run.run_id %></code>
            <span> <%= run.action %> </span>
            <span>status=<%= run.status %></span>
            <span>targets=<%= Enum.join(run.targets, ",") %></span>
          </li>
        </ul>
      </section>
    </main>
    """
  end
end
