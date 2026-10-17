defmodule Counter.View do
  use Baguette.View
  import Counter.Components

  def mount(_args), do: {:ok, %{count: Counter.Store.get()}}

  def render(assigns) do
    ~H"""
    <div class="size-full flex-col items-center justify-center gap-6 bg-background text-foreground">
      <text class="text-3xl font-bold">Count: {@count}</text>
      <div class="flex-row gap-3">
        <.button variant={:ghost} phx-click="dec" aria-label="Decrement">-</.button>
        <.button phx-click="inc" aria-label="Increment">+</.button>
      </div>
    </div>
    """
  end

  def handle_event("inc", _values, assigns),
    do: {:noreply, %{assigns | count: Counter.Store.inc()}}

  def handle_event("dec", _values, assigns),
    do: {:noreply, %{assigns | count: Counter.Store.dec()}}
end
