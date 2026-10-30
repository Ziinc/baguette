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

  test "Ctrl+D clears the done todos, even from the title input; typing fires nothing" do
    for title <- ["Done one", "Open one"] do
      Test.fill(0, "Title", title)
      Test.submit(0, "Title")
    end

    Test.click(0, "Done one")
    Test.keydown(0, "d", [], focus: "Title")
    assert Test.text(0) =~ "Done one"

    Test.keydown(0, "d", [:ctrl], focus: "Title")
    refute Test.text(0) =~ "Done one"
    assert Test.text(0) =~ "Open one"
    assert Test.text(0) =~ "Last key: ctrl+d"
    Test.click(0, "Delete Open one")
  end

  test "buttons carry icons" do
    Test.fill(0, "Title", "Iconic")
    Test.submit(0, "Title")
    assert Test.icons(0, "Add") == ["plus"]
    assert Test.icons(0, "Delete Iconic") == ["trash"]
    Test.click(0, "Delete Iconic")
  end
end
