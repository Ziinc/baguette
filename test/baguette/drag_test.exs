defmodule Baguette.DragTest do
  use ExUnit.Case, async: false
  alias Baguette.Test

  defmodule Board do
    use Baguette.View

    def mount(_args), do: {:ok, %{x: 10, y: 20}}

    def render(assigns) do
      ~H"""
      <div class="relative size-full">
        <div class={"absolute left-[#{@x}px] top-[#{@y}px]"} phx-drag="move" phx-value-id="card"
          aria-label="Card">
          <text>At {@x},{@y}</text>
        </div>
      </div>
      """
    end

    def handle_event("move", %{"id" => "card", "dx" => dx, "dy" => dy}, assigns),
      do: {:noreply, %{assigns | x: assigns.x + dx, y: assigns.y + dy}}
  end

  setup do
    window = System.unique_integer([:positive])
    start_supervised!({Board, window: window})
    %{window: window}
  end

  test "drags arrive as handle_event with dx and dy merged into the values", %{window: window} do
    Test.drag(window, "Card", 30, -5)
    assert Test.text(window) =~ "At 40,15"
  end

  test "dragging a missing control fails", %{window: window} do
    assert_raise ArgumentError, ~r/no draggable element/, fn ->
      Test.drag(window, "Nope", 1, 1)
    end
  end
end
