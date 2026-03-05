defmodule Steward.RunRegistry do
  @moduledoc "In-memory run registry for PoC bootstrapping."
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok), do: {:ok, %{}}
end
