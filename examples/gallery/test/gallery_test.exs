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

  defp flatten(%{"c" => children} = el), do: [el | Enum.flat_map(children, &flatten/1)]
  defp flatten(_), do: []
end
