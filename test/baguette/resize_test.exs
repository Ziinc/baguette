defmodule Baguette.ResizeTest do
  use ExUnit.Case, async: false
  alias Baguette.Test

  defmodule Sized do
    use Baguette.View

    def mount(_args), do: {:ok, %{size: nil}}

    def render(assigns) do
      ~H"""
      <div class="flex-col" phx-window-resize="resized" phx-value-from="sized">
        <text :if={@size}>{elem(@size, 0)} x {elem(@size, 1)} from {elem(@size, 2)}</text>
        <text :if={!@size}>Unsized</text>
      </div>
      """
    end

    def handle_event("resized", %{"width" => w, "height" => h, "from" => from}, assigns),
      do: {:noreply, %{assigns | size: {w, h, from}}}
  end

  defmodule Plain do
    use Baguette.View
    def mount(_args), do: {:ok, %{}}
    def render(assigns), do: ~H"<text>Fixed</text>"
  end

  test "a resize arrives with the window's width and height and phx-value-*" do
    window = System.unique_integer([:positive])
    start_supervised!({Sized, window: window})
    assert Test.text(window) =~ "Unsized"

    Test.resize(window, 390, 844)
    assert Test.text(window) =~ "390 x 844 from sized"
  end

  test "a window without phx-window-resize fails" do
    window = System.unique_integer([:positive])
    start_supervised!({Plain, window: window})

    assert_raise ArgumentError, ~r/no phx-window-resize/, fn -> Test.resize(window, 390, 844) end
  end
end
