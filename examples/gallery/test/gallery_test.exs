defmodule GalleryTest do
  use ExUnit.Case, async: false
  alias Baguette.Test

  test "kit components render as their native tags" do
    tree = Test.tree(0)
    tags = tree |> flatten() |> Enum.map(& &1["t"])
    assert "kit-tag" in tags
    assert "kit-progress" in tags

    Test.click(0, "More")
    assert Test.text(0) =~ "50% uploaded"
  end

  test "the jobs list renders the rows shown" do
    Test.show_rows(0, "jobs", 9_998..9_999)
    assert Test.text(0) =~ "Job 9998 Job 9999"
  end

  test "ctrl-k opens the palette from the jobs panel" do
    Test.keystroke(0, "ctrl-k")
    assert Test.text(0) =~ "Palette closed"
    Test.keystroke(0, "ctrl-k", focus: "Jobs panel")
    assert Test.text(0) =~ "Palette open"
    Test.keystroke(0, "escape")
    assert Test.text(0) =~ "Palette closed"
  end

  defp flatten(%{"c" => children} = el), do: [el | Enum.flat_map(children, &flatten/1)]

  defp flatten(_), do: []
end
