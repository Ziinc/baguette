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
       appearance: App.appearance(),
       entries: [1]
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
        <div
          aria-label="Tween"
          class="w-16 h-6 bg-[#ff0000]"
          animate-to="bg-[#0000ff]"
          duration="600"
        />
        <button phx-click="add_entry" aria-label="Add entry" class="px-2 border border-border">
          Add entry
        </button>
      </div>
      <div class="flex-col">
        <div
          :for={entry <- @entries}
          id={"entry-#{entry}"}
          aria-label={"Entry #{entry}"}
          class="relative h-6 w-48 bg-[#ffffff]"
        >
          <div
            id={"flash-#{entry}"}
            animate="flash"
            easing="linear"
            duration="2000"
            class="absolute inset-0 bg-[#00ff00]"
          />
          <text>Entry {entry}</text>
        </div>
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
      <div class="flex gap-4 items-center">
        <div aria-label="Chart" class="w-32 h-16">
          <canvas class="size-full">
            <rect x="0" y="0" width="64" height="64" class="fill-[#ff0000]" />
            <circle cx="96" cy="32" r="24" class="fill-[#00ff00]" />
            <path d="M 70 60 L 120 60" class="stroke-[#000000]" stroke-width="2" />
          </canvas>
        </div>
        <div aria-label="Pulse" animate="pulse" duration="900" class="w-8 h-8 bg-[#0000ff]" />
        <icon name="loader" animate="spin" class="size-6" />
        <div aria-label="Track" class="w-64 h-2 bg-muted rounded-full">
          <div aria-label="Half" class="w-1/2 h-full bg-primary rounded-l-full" />
        </div>
      </div>
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

  def handle_event("add_entry", _values, assigns),
    do: {:noreply, %{assigns | entries: [hd(assigns.entries) + 1 | assigns.entries]}}

  def handle_event("more", _values, assigns),
    do: {:noreply, %{assigns | done: min(assigns.done + 10, 100)}}
end
