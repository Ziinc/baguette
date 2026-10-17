defmodule Baguette.ViewTest do
  use ExUnit.Case, async: false

  defmodule Toggle do
    use Baguette.View

    def mount(args), do: {:ok, %{on: Keyword.get(args, :on, false), picked: nil}}

    def render(assigns) do
      ~H"""
      <div class="flex-col">
        <text>{if @on, do: "On", else: "Off"}</text>
        <button phx-click="toggle" aria-label="Toggle">Switch</button>
        <button :for={c <- ~w(red blue)} phx-click="pick" phx-value-colour={c}>{c}</button>
        <text :if={@picked}>Picked {@picked}</text>
      </div>
      """
    end

    def handle_event("toggle", _values, assigns), do: {:noreply, %{assigns | on: !assigns.on}}
    def handle_event("pick", %{"colour" => c}, assigns), do: {:noreply, %{assigns | picked: c}}

    def handle_info({:set, on}, assigns), do: {:noreply, %{assigns | on: on}}
  end

  alias Baguette.Test

  setup do
    window = System.unique_integer([:positive])
    pid = start_supervised!({Toggle, window: window, args: [on: false]})
    %{window: window, pid: pid}
  end

  test "renders on mount without a native host", %{window: window} do
    refute Baguette.Host.native?()
    assert Test.text(window) =~ "Off"
  end

  test "clicks route to handle_event and re-render", %{window: window} do
    Test.click(window, "Toggle")
    assert Test.text(window) =~ "On"
    Test.click(window, "Toggle")
    assert Test.text(window) =~ "Off"
  end

  test "phx-value-* attributes arrive as values", %{window: window} do
    Test.click(window, "blue")
    assert Test.text(window) =~ "Picked blue"
  end

  test "other messages go to handle_info", %{window: window, pid: pid} do
    send(pid, {:set, true})
    assert Test.text(window) =~ "On"
  end

  test "clicking a missing control fails", %{window: window} do
    assert_raise ArgumentError, ~r/no clickable element/, fn -> Test.click(window, "Nope") end
    assert_raise ArgumentError, ~r/no clickable element/, fn -> Test.click(window, "Off") end
  end

  test "frames carry the theme tokens", %{window: window} do
    assert %{"theme" => %{}} = Baguette.Host.last_frame(window)
  end
end
