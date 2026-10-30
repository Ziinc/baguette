defmodule Baguette.PickTest do
  use ExUnit.Case, async: false
  alias Baguette.Test

  defmodule Picker do
    use Baguette.View

    def mount(_args), do: {:ok, %{picked: nil, saved: nil}}

    def render(assigns) do
      ~H"""
      <div class="flex-col">
        <button phx-pick-file="picked" accept="csv,xlsx" phx-value-key="path" aria-label="Choose file">
          Choose file
        </button>
        <button phx-pick-save="saved" default-name="out.csv" aria-label="Save as">Save as</button>
        <button phx-click="noop" aria-label="Plain">Plain</button>
        <text :if={@picked}>Picked {@picked["path"]} for {@picked["key"]}</text>
        <text :if={@saved}>Saved to {@saved}</text>
      </div>
      """
    end

    def handle_event("picked", values, assigns), do: {:noreply, %{assigns | picked: values}}

    def handle_event("saved", %{"path" => path}, assigns),
      do: {:noreply, %{assigns | saved: path}}

    def handle_event("noop", _values, assigns), do: {:noreply, assigns}
  end

  setup do
    window = System.unique_integer([:positive])
    start_supervised!({Picker, window: window})
    %{window: window}
  end

  test "pick_file sends the picker's event with the path and its phx-value-*", %{window: w} do
    Test.pick_file(w, "Choose file", "/tmp/orders.csv")
    assert Test.text(w) =~ "Picked /tmp/orders.csv for path"
  end

  test "pick_file works for save pickers too", %{window: w} do
    Test.pick_file(w, "Save as", "/tmp/out.csv")
    assert Test.text(w) =~ "Saved to /tmp/out.csv"
  end

  test "picking from something that is not a picker fails", %{window: w} do
    assert_raise ArgumentError, ~r/no file picker labelled/, fn ->
      Test.pick_file(w, "Plain", "/tmp/x")
    end
  end
end
