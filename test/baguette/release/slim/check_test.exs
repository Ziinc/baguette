defmodule Baguette.Release.Slim.CheckTest do
  use ExUnit.Case, async: false

  alias Baguette.Release.Slim.Fixture

  @moduletag timeout: 300_000
  @options [keep: [modules: [DemoDep.Safe]]]

  test "passes when the suite loads only modules the release keeps" do
    assert {out, 0} = Fixture.mix(["test"], "test", @options)
    assert out =~ "1 passed"
    refute out =~ "would purge"
  end

  test "fails when the suite loads a module the release would purge" do
    assert {out, status} = Fixture.mix(["test"], "test", @options, [{"LOAD_UNUSED", "1"}])
    assert status != 0
    assert out =~ "DemoDep.Unused (demo_dep)"
    refute out =~ "DemoDep.Safe"
    assert out =~ "baguette: [keep: [modules: [DemoDep.Unused, DemoDep.UnusedToo]]]"
  end
end
