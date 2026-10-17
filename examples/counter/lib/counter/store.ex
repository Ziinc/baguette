defmodule Counter.Store do
  @moduledoc "Holds the count. The view only renders what this returns."
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)

  def get, do: GenServer.call(__MODULE__, :get)
  def inc, do: GenServer.call(__MODULE__, {:add, 1})
  def dec, do: GenServer.call(__MODULE__, {:add, -1})

  @impl true
  def init(count), do: {:ok, count}

  @impl true
  def handle_call(:get, _from, count), do: {:reply, count, count}
  def handle_call({:add, n}, _from, count), do: {:reply, count + n, count + n}
end
