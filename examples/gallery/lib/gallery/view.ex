defmodule Gallery.View do
  @moduledoc "Baguette's native API on one screen: gpui-kit's components and a long list."
  use Baguette.View
  import Baguette.Kit
  alias Baguette.{App, Clipboard, Window}

  keymap("ctrl-k", :open_palette, context: "Jobs")
  keymap("escape", :close_palette)

  def mount(_args) do
    {:ok,
     %{
       done: 40,
       palette: false,
       pasted: nil,
       title: nil,
       details: false,
       appearance: App.appearance()
     }}
  end

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
      <div class="flex gap-2 items-center">
        <button
          key-context="Jobs"
          tabindex="1"
          aria-label="Jobs panel"
          class="px-2 border border-border"
        >
          Jobs
        </button>
        <text>{if @palette, do: "Palette open", else: "Palette closed"}</text>
      </div>
      <div class="flex gap-2 items-center">
        <button phx-click="copy" aria-label="Copy" class="px-2 border border-border">Copy</button>
        <button phx-click="paste" aria-label="Paste" class="px-2 border border-border">Paste</button>
        <button phx-click="rename" aria-label="Rename" class="px-2 border border-border">Rename</button>
        <button phx-click="details" aria-label="Details" class="px-2 border border-border">Details</button>
      </div>
      <text>Pasted: {@pasted}</text>
      <text>Title: {@title}</text>
      <text>Details {if @details, do: "open", else: "closed"}</text>
      <text>Appearance: {@appearance}</text>
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

  def handle_action(:open_palette, assigns), do: {:noreply, %{assigns | palette: true}}
  def handle_action(:close_palette, assigns), do: {:noreply, %{assigns | palette: false}}

  def handle_event("copy", _values, assigns) do
    Clipboard.write("copied from gallery")
    {:noreply, assigns}
  end

  def handle_event("paste", _values, assigns),
    do: {:noreply, %{assigns | pasted: Clipboard.read()}}

  def handle_event("rename", _values, assigns) do
    Window.set_title(0, "Gallery renamed")
    {:noreply, %{assigns | title: Window.info(0).title}}
  end

  def handle_event("details", _values, assigns) do
    Window.open(1, title: "Details", width: 320, height: 200)
    {:noreply, %{assigns | details: Window.info(1) != nil}}
  end

  def handle_event("more", _values, assigns),
    do: {:noreply, %{assigns | done: min(assigns.done + 10, 100)}}
end
