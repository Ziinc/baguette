defmodule Baguette.KeymapTest do
  use ExUnit.Case, async: false
  alias Baguette.Test

  defmodule Palette do
    use Baguette.View

    keymap("secondary-k", :open_palette, context: "Jobs")
    keymap("escape", :close)

    def mount(_args), do: {:ok, %{open: false}}

    def render(assigns) do
      ~H"""
      <div class="flex-col">
        <div key-context="Jobs" tabindex="2" aria-label="Jobs"><text>Jobs</text></div>
        <button tabindex="1" aria-label="Other">Other</button>
        <text>{if @open, do: "Palette open", else: "Closed"}</text>
      </div>
      """
    end

    def handle_action(:open_palette, assigns), do: {:noreply, %{assigns | open: true}}
    def handle_action(:close, assigns), do: {:noreply, %{assigns | open: false}}
  end

  setup do
    window = System.unique_integer([:positive])
    start_supervised!({Palette, window: window})
    %{window: window}
  end

  test "the view's keymap goes to the host with its first frame", %{window: window} do
    Test.text(window)

    assert Baguette.Host.last_frame(window)["keymap"] == [
             %{"keys" => "secondary-k", "action" => "open_palette", "context" => "Jobs"},
             %{"keys" => "escape", "action" => "close"}
           ]

    assert Palette.__keymap__() == [
             {"secondary-k", :open_palette, "Jobs"},
             {"escape", :close, nil}
           ]
  end

  test "a binding with a context fires only with focus inside it", %{window: window} do
    Test.keystroke(window, "secondary-k")
    assert Test.text(window) =~ "Closed"

    Test.keystroke(window, "secondary-k", focus: "Other")
    assert Test.text(window) =~ "Closed"

    Test.keystroke(window, "secondary-k", focus: "Jobs")
    assert Test.text(window) =~ "Palette open"

    Test.keystroke(window, "escape")
    assert Test.text(window) =~ "Closed"
  end

  test "tabindex orders focus", %{window: window} do
    assert Test.focus_order(window) == ["Other", "Jobs"]
  end

  test "a keystroke nothing binds does nothing", %{window: window} do
    Test.keystroke(window, "f5")
    assert Test.text(window) =~ "Closed"
  end
end
