defmodule SlimBeam.PruneTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    for file <- ~w(lib/a-1/src/a.erl lib/a-1/include/a.hrl lib/a-1/doc/a.html lib/a-1/ebin/a.beam
                   lib/a-1/priv/big.txt lib/a-1/priv/keep.so) do
      path = Path.join(root, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "12345")
    end

    :ok
  end

  test "removes the default globs", %{tmp_dir: root} do
    removed = SlimBeam.Prune.run(root, [])

    assert Enum.sort(removed) == [
             %{path: "lib/a-1/doc", bytes: 5, reason: "prune: lib/*/doc"},
             %{path: "lib/a-1/include", bytes: 5, reason: "prune: lib/*/include"},
             %{path: "lib/a-1/src", bytes: 5, reason: "prune: lib/*/src"}
           ]

    assert File.exists?(Path.join(root, "lib/a-1/ebin/a.beam"))
  end

  test "adds the user's globs", %{tmp_dir: root} do
    removed = SlimBeam.Prune.run(root, ["lib/*/priv/*.txt"])

    assert %{path: "lib/a-1/priv/big.txt", bytes: 5, reason: "prune: lib/*/priv/*.txt"} in removed
    assert File.exists?(Path.join(root, "lib/a-1/priv/keep.so"))
  end
end
