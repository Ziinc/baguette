defmodule SlimBeam.CheckTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000
  @options [keep: [modules: [DemoDep.Safe]]]
  @demo Path.expand("../fixtures/demo", __DIR__)

  defp mix_test(env) do
    System.cmd("mix", ["test"],
      cd: @demo,
      env: [{"MIX_ENV", "test"}, {"SLIM_BEAM", inspect(@options)} | env],
      stderr_to_stdout: true
    )
  end

  test "passes when the suite loads only modules the release keeps" do
    assert {out, 0} = mix_test([])
    assert out =~ "1 passed"
    refute out =~ "SlimBeam"
  end

  test "fails when the suite loads a module the release would purge" do
    assert {out, status} = mix_test([{"LOAD_UNUSED", "1"}])
    assert status != 0
    assert out =~ "DemoDep.Unused (demo_dep)"
    refute out =~ "DemoDep.Safe"
    assert out =~ "slim_beam: [keep: [modules: [DemoDep.Unused, DemoDep.UnusedToo]]]"
  end
end
