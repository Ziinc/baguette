defmodule Baguette.Release.Slim.ReleaseTest do
  # Builds the fixture release, so the tests take turns.
  use ExUnit.Case, async: false

  alias Baguette.Release.Slim.Fixture

  @moduletag timeout: 300_000

  setup_all do
    {path, _out} = Fixture.release!(keep: [modules: [DemoDep.Safe]])
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

  test "keeps the project's own apps whole", %{path: path} do
    assert File.exists?(Path.join(Fixture.ebin(path, :demo), "Elixir.Demo.beam"))
  end

  test "purges Elixir and IEx, but keeps kernel, stdlib and logger whole", %{path: path} do
    unreachable =
      for %{"reason" => "unreachable", "path" => file} <- report(path)["removed"],
          do: file |> Path.split() |> Enum.at(1) |> String.replace(~r/-[^-]*$/, "")

    assert "elixir" in unreachable
    assert "iex" in unreachable
    for app <- ~w(kernel stdlib logger), do: refute(app in unreachable, app)
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

  test "prunes include directories", %{path: path} do
    assert Path.wildcard(Path.join(path, "lib/*/include")) == []
  end

  test "writes a report of what was removed and why", %{path: path} do
    report = report(path)

    assert report["before"]["total"] > report["after"]["total"]
    assert report["before"]["apps"]["demo_dep"] > report["after"]["apps"]["demo_dep"]

    assert %{
             "path" => "lib/demo_dep-0.1.0/ebin/Elixir.DemoDep.Unused.beam",
             "reason" => "unreachable"
           } =
             Enum.find(report["removed"], &(&1["path"] =~ "DemoDep.Unused.beam"))

    assert Enum.any?(report["removed"], &(&1["reason"] == "prune: lib/*/include"))
  end

  test "the slimmed release evals", %{path: path} do
    assert {out, 0} = Fixture.run(path, ["eval", "IO.puts(Demo.hello())"])
    assert out =~ "hello,configured,runtime,safe,struct 1"
  end

  test "the slimmed release boots in embedded mode and logs", %{path: path} do
    node = "demo_#{System.unique_integer([:positive])}"
    env = [{"DEMO_BOOT_CHECK", "1"}, {"RELEASE_MODE", "embedded"}, {"RELEASE_NODE", node}]

    port =
      Port.open({:spawn_executable, Path.join(path, "bin/demo")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["start"],
        env: charlist_env(env)
      ])

    on_exit(fn -> Fixture.run(path, ["stop"], [{"RELEASE_NODE", node}]) end)

    out = read_until(port, ["demo booted", "hello,configured,runtime,safe,struct 1"], "")
    assert out =~ "[info] demo booted"
  end

  defp read_until(port, needles, out) do
    if Enum.all?(needles, &(out =~ &1)) do
      out
    else
      receive do
        {^port, {:data, data}} -> read_until(port, needles, out <> data)
      after
        30_000 -> flunk("the release printed only:\n" <> out)
      end
    end
  end

  defp report(path) do
    [json] = Path.wildcard(Path.join(path, "releases/*/slim.json"))
    json |> File.read!() |> JSON.decode!()
  end

  defp charlist_env(env), do: for({k, v} <- env, do: {~c"#{k}", ~c"#{v}"})
end
