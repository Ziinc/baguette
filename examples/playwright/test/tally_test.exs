defmodule TallyTest do
  # The view on window 0, headless.
  use ExUnit.Case, async: false
  alias Baguette.Test

  test "votes add up" do
    Test.click(0, "Reset")
    Test.click(0, "Vote for Elixir")
    Test.click(0, "Vote for Rust")
    assert Test.text(0) =~ "Total: 2"
  end
end
