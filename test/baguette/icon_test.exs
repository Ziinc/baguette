defmodule Baguette.IconTest do
  use ExUnit.Case, async: false
  alias Baguette.Test

  defmodule Toolbar do
    use Baguette.View

    def mount(_args), do: {:ok, %{}}

    def render(assigns) do
      ~H"""
      <div class="flex-row gap-1">
        <button phx-click="undo" title="Undo (Ctrl+Z)" class="flex-row gap-1">
          <icon name="undo-2" class="size-4 text-foreground" />
          <text>Undo</text>
        </button>
        <button phx-click="zoom" aria-label="Zoom in"><icon name="zoom-in" /></button>
      </div>
      """
    end
  end

  setup do
    window = System.unique_integer([:positive])
    start_supervised!({Toolbar, window: window})
    %{window: window}
  end

  test "icons/1 lists the icons drawn, by name", %{window: window} do
    assert Test.icons(window) == ["undo-2", "zoom-in"]
  end

  test "an icon adds no text, so a button keeps its label", %{window: window} do
    buttons = for %{"t" => "button"} = el <- Test.find_all(window, "Undo"), do: el
    assert [%{"a" => %{"title" => "Undo (Ctrl+Z)"}}] = buttons

    assert [_] = Test.find_all(window, "Zoom in")
  end

  test "icons/2 lists the icons inside the element labelled `label`", %{window: window} do
    assert Test.icons(window, "Zoom in") == ["zoom-in"]
  end
end
