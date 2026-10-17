defmodule CounterTest do
  # The app's own view on window 0, backed by the app's Counter.Store.
  use ExUnit.Case, async: false
  alias Baguette.Test

  test "clicks update the count held in Counter.Store" do
    start = Counter.Store.get()
    assert Test.text(0) =~ "Count: #{start}"

    Test.click(0, "Increment")
    Test.click(0, "Increment")
    Test.click(0, "Decrement")
    assert Test.text(0) =~ "Count: #{start + 1}"
    assert Counter.Store.get() == start + 1
  end
end
