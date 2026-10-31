defmodule Baguette.RenderTest do
  # Draws with GPUI's headless renderer, so it needs Vulkan (lavapipe) on
  # Linux: run with `mix test --only render`.
  use ExUnit.Case, async: false
  @moduletag :render
  @moduletag timeout: :timer.minutes(10)

  defmodule Lamp do
    use Baguette.View

    def mount(_args), do: {:ok, %{on: false}}

    def render(assigns) do
      ~H"""
      <div class={["size-full", if(@on, do: "bg-[#facc15]", else: "bg-black")]}>
        <button phx-click="toggle" aria-label="Toggle" class="p-4 bg-white">Switch</button>
      </div>
      """
    end

    def handle_event("toggle", _values, assigns), do: {:noreply, %{assigns | on: !assigns.on}}
  end

  alias Baguette.Test

  test "render_png draws the last frame at 2x with the host's view code" do
    window = System.unique_integer([:positive])
    start_supervised!({Lamp, window: window})

    off = Test.render_png(window, width: 120, height: 80)
    assert <<0x89, "PNG", _::binary-size(12), 240::32, 160::32, _::binary>> = off

    Test.click(window, "Toggle")
    refute Test.render_png(window, width: 120, height: 80) == off
  end

  test "render_png fails for a window that rendered nothing" do
    assert_raise ArgumentError, ~r/nothing rendered/, fn -> Test.render_png(-1) end
  end
end
