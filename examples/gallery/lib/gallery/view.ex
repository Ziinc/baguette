defmodule Gallery.View do
  @moduledoc "Baguette's native API on one screen: gpui-kit's components and a long list."
  use Baguette.View
  import Baguette.Kit

  def mount(_args), do: {:ok, %{done: 40}}

  def render(assigns) do
    ~H"""
    <div class="size-full flex-col gap-4 p-6">
      <div class="flex gap-2 items-center">
        <.tag variant="danger" pill>Failed</.tag>
        <.tag variant="success">Done</.tag>
        <.kbd keys="ctrl-k" />
        <.spinner size="small" />
      </div>
      <.progress value={@done} aria-label="Upload" class="w-64" />
      <text>{@done}% uploaded</text>
      <button class="px-3 py-1 rounded-md bg-primary" phx-click="more" aria-label="More">
        More
      </button>
      <.skeleton class="w-64 h-4" />
      <list id="jobs" rows={10_000} phx-rows="jobs" class="h-40 w-64 border border-border" />
    </div>
    """
  end

  def handle_rows("jobs", range, assigns) do
    rows =
      for i <- range do
        assigns = %{i: i}

        ~H"""
        <div class="h-8 px-2 flex items-center">
          <text>Job {@i}</text>
        </div>
        """
      end

    {:reply, rows, assigns}
  end

  def handle_event("more", _values, assigns),
    do: {:noreply, %{assigns | done: min(assigns.done + 10, 100)}}
end
