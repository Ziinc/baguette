defmodule SlimBeam.ErtsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    erts = Path.join(root, "erts-17.1.1")

    for file <- ~w(bin/beam.smp bin/erl_child_setup bin/inet_gethost bin/epmd include/erl_nif.h
                   lib/liberts.a doc/README man/man1/erl.1) do
      path = Path.join(erts, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, String.duplicate("x", 10))
    end

    %{erts: erts}
  end

  test "keeps only the listed executables", %{tmp_dir: root, erts: erts} do
    removed = SlimBeam.Erts.run(root, keep: ["erl_child_setup", "inet_gethost"])

    assert File.ls!(Path.join(erts, "bin")) |> Enum.sort() == ["erl_child_setup", "inet_gethost"]
    for dir <- ~w(include lib doc man), do: refute(File.exists?(Path.join(erts, dir)))

    assert %{path: "erts-17.1.1/bin/beam.smp", bytes: 10, reason: "erts"} in removed
    assert %{path: "erts-17.1.1/include", bytes: 10, reason: "erts"} in removed
    assert length(removed) == 6
  end

  test "does nothing without a keep list", %{tmp_dir: root, erts: erts} do
    assert SlimBeam.Erts.run(root, []) == []
    assert File.exists?(Path.join(erts, "bin/beam.smp"))
  end

  test "does nothing without ERTS", %{tmp_dir: root, erts: erts} do
    File.rm_rf!(erts)
    assert SlimBeam.Erts.run(root, keep: []) == []
  end
end
