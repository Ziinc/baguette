defmodule Baguette.FormTest do
  use ExUnit.Case, async: false
  alias Baguette.Test

  defmodule Todos do
    use Baguette.View

    def mount(_args), do: {:ok, %{draft: "", todos: [], changes: [], url: "", done: false}}

    def render(assigns) do
      ~H"""
      <div class="flex-col">
        <form phx-submit="add" phx-change="draft" aria-label="New todo form">
          <input name="title" value={@draft} placeholder="What needs doing?" aria-label="Title" />
          <input name="tag" value="home" aria-label="Tag" />
          <button type="submit">Add</button>
        </form>
        <input name="url" value={@url} phx-change="url" aria-label="URL" />
        <input type="checkbox" checked={@done} phx-click="toggle" aria-label="Done" />
        <text>Draft: {@draft}</text>
        <text>URL: {@url}</text>
        <text>Done: {@done}</text>
        <ul>
          <li :for={todo <- @todos}>{todo}</li>
        </ul>
      </div>
      """
    end

    def handle_event("draft", values, assigns),
      do: {:noreply, %{assigns | draft: values["title"], changes: [values | assigns.changes]}}

    def handle_event("add", %{"title" => title, "tag" => tag}, assigns),
      do: {:noreply, %{assigns | todos: assigns.todos ++ ["#{title} ##{tag}"], draft: ""}}

    def handle_event("url", %{"url" => url}, assigns), do: {:noreply, %{assigns | url: url}}

    def handle_event("toggle", %{"checked" => checked}, assigns),
      do: {:noreply, %{assigns | done: checked}}
  end

  setup do
    window = System.unique_integer([:positive])
    pid = start_supervised!({Todos, window: window})
    %{window: window, pid: pid}
  end

  test "fill sends the form's phx-change with every named value and _target", %{
    window: w,
    pid: pid
  } do
    Test.fill(w, "Title", "Buy milk")
    assert Test.text(w) =~ "Draft: Buy milk"

    assert [%{"title" => "Buy milk", "tag" => "home", "_target" => "title"}] =
             :sys.get_state(pid).assigns.changes
  end

  test "an input outside a form sends its own phx-change", %{window: w} do
    Test.fill(w, "URL", "https://example.com")
    assert Test.text(w) =~ "URL: https://example.com"
  end

  test "inputs are found by aria-label, placeholder or name", %{window: w} do
    Test.fill(w, "What needs doing?", "a")
    assert Test.value(w, "Title") == "a"
    Test.fill(w, "url", "b")
    assert Test.value(w, "URL") == "b"
  end

  test "submit sends phx-submit with the form's values, typed ones included", %{window: w} do
    Test.fill(w, "Title", "Buy milk")
    Test.submit(w, "Title")
    assert Test.text(w) =~ "Buy milk #home"
  end

  test "a view resetting value replaces what was typed", %{window: w} do
    Test.fill(w, "Title", "Buy milk")
    Test.submit(w, "New todo form")
    assert Test.value(w, "Title") == ""
  end

  test "clicking a submit button submits its form", %{window: w} do
    Test.fill(w, "Title", "Walk dog")
    Test.click(w, "Add")
    assert Test.text(w) =~ "Walk dog #home"
  end

  test "checkbox clicks carry the new checked state", %{window: w} do
    Test.click(w, "Done")
    assert Test.text(w) =~ "Done: true"
    Test.click(w, "Done")
    assert Test.text(w) =~ "Done: false"
  end

  test "filling something that is not an input fails", %{window: w} do
    assert_raise ArgumentError, ~r/no input labelled/, fn -> Test.fill(w, "Nope", "x") end
    assert_raise ArgumentError, ~r/no form/, fn -> Test.submit(w, "URL") end
  end
end
