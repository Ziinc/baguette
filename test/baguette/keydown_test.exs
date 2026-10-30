defmodule Baguette.KeydownTest do
  use ExUnit.Case, async: false
  alias Baguette.Test

  defmodule Editor do
    use Baguette.View

    def mount(_args), do: {:ok, %{log: [], escapes: 0}}

    def render(assigns) do
      ~H"""
      <div class="flex-col" phx-window-keydown="key" phx-value-from="editor">
        <div phx-window-keydown="escape" phx-key="Escape" />
        <input name="title" aria-label="Title" />
        <text>Escapes: {@escapes}</text>
        <text :for={entry <- @log}>{entry}</text>
      </div>
      """
    end

    def handle_event("key", values, assigns) do
      %{"key" => key, "ctrl" => ctrl, "shift" => shift, "alt" => alt, "meta" => meta} = values

      mods =
        for {true, name} <- [{ctrl, "ctrl"}, {shift, "shift"}, {alt, "alt"}, {meta, "meta"}],
            do: name

      entry = Enum.join(mods ++ [key], "+") <> " from " <> values["from"]
      {:noreply, %{assigns | log: assigns.log ++ [entry]}}
    end

    def handle_event("escape", _values, assigns),
      do: {:noreply, %{assigns | escapes: assigns.escapes + 1}}
  end

  defmodule Plain do
    use Baguette.View
    def mount(_args), do: {:ok, %{}}
    def render(assigns), do: ~H"<text>No shortcuts</text>"
  end

  setup do
    window = System.unique_integer([:positive])
    start_supervised!({Editor, window: window})
    %{window: window}
  end

  test "keys arrive with the key, every modifier and the element's phx-value-*",
       %{window: window} do
    Test.keydown(window, "z", [:ctrl])
    Test.keydown(window, "z", [:ctrl, :shift])
    Test.keydown(window, "Enter", [:meta])
    assert Test.text(window) =~ "ctrl+z from editor"
    assert Test.text(window) =~ "ctrl+shift+z from editor"
    assert Test.text(window) =~ "meta+Enter from editor"
  end

  test "phx-key only fires for its key, ignoring case", %{window: window} do
    Test.keydown(window, "a")
    assert Test.text(window) =~ "Escapes: 0"
    Test.keydown(window, "escape")
    assert Test.text(window) =~ "Escapes: 1"
  end

  test "typing in a focused text input fires no shortcut; chords do", %{window: window} do
    Test.keydown(window, "a", [], focus: "Title")
    Test.keydown(window, "Escape", [], focus: "Title")
    refute Test.text(window) =~ "from editor"
    assert Test.text(window) =~ "Escapes: 0"

    Test.keydown(window, "s", [:ctrl], focus: "Title")
    assert Test.text(window) =~ "ctrl+s from editor"
  end

  test "a chord the focused input handles itself (its undo) fires nothing", %{window: window} do
    Test.keydown(window, "z", [:ctrl], focus: "Title")
    refute Test.text(window) =~ "from editor"
  end

  test "a window without phx-window-keydown fails" do
    window = System.unique_integer([:positive])
    start_supervised!({Plain, window: window})

    assert_raise ArgumentError, ~r/no phx-window-keydown/, fn ->
      Test.keydown(window, "z", [:ctrl])
    end
  end
end
