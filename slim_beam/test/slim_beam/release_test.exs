defmodule SlimBeam.ReleaseTest do
  # Builds the fixture release, so the tests take turns.
  use ExUnit.Case, async: false

  alias SlimBeam.Fixture

  @moduletag timeout: 300_000

  setup_all do
    {path, _out} = Fixture.release!(safelist: [modules: [DemoDep.Safe]])
    %{path: path}
  end

  test "purges the dependency modules nothing reaches", %{path: path} do
    ebin = Fixture.ebin(path, :demo_dep)
    beams = ebin |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".beam"))

    refute "Elixir.DemoDep.Unused.beam" in beams
    refute "Elixir.DemoDep.UnusedToo.beam" in beams

    for kept <- ~w(DemoDep DemoDep.Helper DemoDep.Application DemoDep.Configured
                   DemoDep.Runtime DemoDep.Safe DemoDep.Struct String.Chars.DemoDep.Struct),
        do: assert("Elixir.#{kept}.beam" in beams)
  end

  test "keeps the project's own apps and OTP whole", %{path: path} do
    assert File.exists?(Path.join(Fixture.ebin(path, :demo), "Elixir.Demo.beam"))
    assert File.exists?(Path.join(Fixture.ebin(path, :stdlib), "gb_sets.beam"))
  end

  test "rewrites the .app modules list", %{path: path} do
    {:ok, [{:application, :demo_dep, props}]} =
      :file.consult(Path.join(Fixture.ebin(path, :demo_dep), "demo_dep.app"))

    refute DemoDep.Unused in props[:modules]
    assert DemoDep.Helper in props[:modules]
  end

  test "rewrites the boot scripts", %{path: path} do
    [version] = Path.wildcard(Path.join(path, "releases/*/start.script"))
    {:ok, [{:script, _, instructions}]} = :file.consult(version)
    loaded = for {:primLoad, modules} <- instructions, module <- modules, do: module

    assert DemoDep.Helper in loaded
    refute DemoDep.Unused in loaded
  end

  test "the slimmed release evals", %{path: path} do
    assert {out, 0} = Fixture.run(path, ["eval", "IO.puts(Demo.hello())"])
    assert out =~ "hello,configured,runtime,safe,struct 1"
  end

  test "the slimmed release boots in embedded mode", %{path: path} do
    env = [{"DEMO_BOOT_CHECK", "1"}, {"RELEASE_MODE", "embedded"}]

    port =
      Port.open({:spawn_executable, Path.join(path, "bin/demo")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["start"],
        env: charlist_env(env)
      ])

    assert_receive {^port, {:data, out}}, 30_000
    assert out =~ "hello,configured,runtime,safe,struct 1"
    {:os_pid, pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["#{pid}"])
  end

  defp charlist_env(env), do: for({k, v} <- env, do: {~c"#{k}", ~c"#{v}"})
end
