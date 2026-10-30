defmodule Todo.View do
  @moduledoc "A to-do list: a form with a text input, checkboxes in a list."
  use Baguette.View

  def mount(_args), do: {:ok, %{draft: "", todos: [], next: 1}}

  def render(assigns) do
    ~H"""
    <div class="size-full flex-col gap-4 p-6 bg-[#ffffff] text-[#0f172a]">
      <h1 class="text-2xl font-bold">Todos</h1>
      <form phx-change="draft" phx-submit="add" aria-label="New todo" class="flex-row gap-2">
        <input name="title" value={@draft} placeholder="What needs to be done?" aria-label="Title"
          class="flex-1" />
        <button type="submit" class="px-3 py-1 rounded-md bg-[#2563eb] text-[#ffffff]">Add</button>
      </form>
      <ul aria-label="Todos" class="flex-col gap-1">
        <li :for={todo <- @todos} class="flex-row items-center justify-between gap-2">
          <div class="flex-row items-center gap-2">
            <input type="checkbox" checked={todo.done} phx-click="toggle" phx-value-id={todo.id}
              aria-label={todo.title} />
            <text class={if todo.done, do: "text-[#94a3b8]", else: ""}>{todo.title}</text>
          </div>
          <button phx-click="delete" phx-value-id={todo.id} aria-label={"Delete #{todo.title}"}
            class="px-2 text-sm">Delete</button>
        </li>
      </ul>
      <text>{Enum.count(@todos, &(not &1.done))} of {length(@todos)} left</text>
    </div>
    """
  end

  def handle_event("draft", %{"title" => title}, assigns), do: {:noreply, %{assigns | draft: title}}

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
