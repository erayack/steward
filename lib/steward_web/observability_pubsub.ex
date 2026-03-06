defmodule StewardWeb.ObservabilityPubSub do
  @moduledoc "Single-topic PubSub helper for observability updates."

  @pubsub Steward.PubSub
  @topic "observability:updated"

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @spec unsubscribe() :: :ok
  def unsubscribe do
    Phoenix.PubSub.unsubscribe(@pubsub, @topic)
  end

  @spec broadcast_update(map()) :: :ok
  def broadcast_update(payload \\ %{}) when is_map(payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, Map.put(payload, :event, :observability_updated))
    :ok
  end
end
