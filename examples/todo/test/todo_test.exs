defmodule TodoTest do
  use ExUnit.Case, async: false
  alias Baguette.Test

  test "add, check and delete todos" do
    Test.fill(0, "Title", "Buy milk")
    Test.submit(0, "Title")
    assert Test.value(0, "Title") == ""

    Test.fill(0, "Title", "Walk dog")
    Test.click(0, "Add")
    assert Test.text(0) =~ "2 of 2 left"

    Test.click(0, "Buy milk")
    assert Test.text(0) =~ "1 of 2 left"

    Test.click(0, "Delete Walk dog")
    assert Test.text(0) =~ "0 of 1 left"
  end

  test "the note echoes what is typed" do
    Test.fill(0, "Note", "noted")
    assert Test.text(0) =~ "Note: noted"
  end
end
