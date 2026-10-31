defmodule Todo.View do
  @moduledoc """
  A to-do list: a form with a text input, checkboxes in a list, icons, and
  a window shortcut (Ctrl+D, or Cmd+D, clears the done todos).
  """
  use Baguette.View

  def mount(_args), do: {:ok, %{draft: "", note: "", todos: [], next: 1, last_key: "none"}}

  def render(assigns) do
    ~H"""
    <div class="size-full flex-col gap-4 p-6 bg-[#ffffff] text-[#0f172a]" phx-window-keydown="key">
      <h1 class="text-2xl font-bold">Todos</h1>
      <form phx-change="draft" phx-submit="add" aria-label="New todo" class="flex-row gap-2">
        <input
          name="title"
          value={@draft}
          placeholder="What needs to be done?"
          aria-label="Title"
          class="flex-1"
        />
        <button
          type="submit"
          class="flex-row items-center gap-1 px-3 py-1 rounded-md bg-[#2563eb] text-[#ffffff]"
        >
          <icon name="plus" class="size-4" /><text>Add</text>
        </button>
      </form>
      <ul aria-label="Todos" class="flex-col gap-1">
        <li :for={todo <- @todos} class="flex-row items-center justify-between gap-2">
          <div class="flex-row items-center gap-2">
            <input
              type="checkbox"
              checked={todo.done}
              phx-click="toggle"
              phx-value-id={todo.id}
              aria-label={todo.title}
            />
            <text class={if todo.done, do: "text-[#94a3b8]", else: ""}>{todo.title}</text>
          </div>
          <button
            phx-click="delete"
            phx-value-id={todo.id}
            aria-label={"Delete #{todo.title}"}
            title="Delete this todo"
            class="flex-row items-center gap-1 px-2 text-sm"
          >
            <icon name="trash" class="size-4 text-[#dc2626]" /><text>Delete</text>
          </button>
        </li>
      </ul>
      <text>{Enum.count(@todos, &(not &1.done))} of {length(@todos)} left</text>
      <text>Last key: {@last_key}</text>
      <%!-- A short scrolling panel whose input starts below its fold. --%>
      <div
        aria-label="Notes"
        class="h-[64px] flex-none flex-col overflow-y-auto border border-[#e2e8f0]"
      >
        <div class="h-[160px] flex-none" />
        <input name="note" value={@note} phx-change="note" aria-label="Note" />
      </div>
      <text>Note: {@note}</text>
    </div>
    """
  end

  def handle_event("draft", %{"title" => title}, assigns),
    do: {:noreply, %{assigns | draft: title}}

  # Every keystroke the window hears; Ctrl+D (Cmd+D on a Mac) clears the done.
  def handle_event("key", %{"key" => key} = mods, assigns) do
    held = for m <- ~w(ctrl shift alt meta), mods[m], do: m
    assigns = %{assigns | last_key: Enum.join(held ++ [key], "+")}

    if key == "d" and (mods["ctrl"] or mods["meta"]),
      do: {:noreply, %{assigns | todos: Enum.reject(assigns.todos, & &1.done)}},
      else: {:noreply, assigns}
  end

  def handle_event("note", %{"note" => note}, assigns), do: {:noreply, %{assigns | note: note}}

  def handle_event("add", %{"title" => title}, assigns) do
    case String.trim(title) do
      "" ->
        {:noreply, assigns}

      title ->
        todo = %{id: "#{assigns.next}", title: title, done: false}
        {:noreply, %{assigns | todos: assigns.todos ++ [todo], draft: "", next: assigns.next + 1}}
    end
  end

  def handle_event("toggle", %{"id" => id, "checked" => checked}, assigns),
    do: {:noreply, update_todo(assigns, id, &%{&1 | done: checked})}

  def handle_event("delete", %{"id" => id}, assigns),
    do: {:noreply, %{assigns | todos: Enum.reject(assigns.todos, &(&1.id == id))}}

  defp update_todo(assigns, id, fun),
    do: %{assigns | todos: Enum.map(assigns.todos, &if(&1.id == id, do: fun.(&1), else: &1))}
end
