defmodule Baguette.PatchTest do
  use ExUnit.Case, async: true
  alias Baguette.Patch

  # The native host applies the same patches (view.rs reads this fixture).
  @cases "test/fixtures/patches.json" |> File.read!() |> JSON.decode!()

  for %{"name" => name} = c <- @cases do
    @case c
    test "diffs #{name}" do
      %{"old" => old, "new" => new, "patch" => patch} = @case
      assert Patch.diff(old, new) == patch
      assert Patch.apply(old, patch) == new
    end
  end

  test "patches rebuild any new tree from the old one" do
    trees = for %{"old" => old, "new" => new} <- @cases, tree <- [old, new], do: tree

    for old <- trees, new <- trees do
      assert Patch.apply(old, Patch.diff(old, new)) == new
    end
  end
end
