defmodule BoardTest do
  use ExUnit.Case, async: false
  alias Baguette.Test

  test "dragging the card moves it" do
    assert Test.text(0) =~ "At 40,40"
    Test.drag(0, "Card", 100, 50)
    assert Test.text(0) =~ "At 140,90"
  end
end
