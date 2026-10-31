defmodule SlimBeam.Erts do
  @moduledoc false
  # With a `keep:` list, removes every ERTS executable not on it, and ERTS's
  # include, lib, doc and man directories.

  alias SlimBeam.Files

  @doc "Trims the ERTS in the release at `root`. Returns the report entries."
  def run(root, opts) do
    keep = opts[:keep]

    case Path.wildcard(Path.join(root, "erts-*")) do
      [erts] when is_list(keep) ->
        erts = Path.basename(erts)
        bin = Path.join([root, erts, "bin"])

        executables =
          for file <- Enum.sort(File.ls!(bin)),
              file not in keep,
              do: Files.remove!(root, Path.join([erts, "bin", file]), "erts")

        dirs =
          for dir <- ~w(include lib doc man),
              File.exists?(Path.join([root, erts, dir])),
              do: Files.remove!(root, Path.join(erts, dir), "erts")

        executables ++ dirs

      _ ->
        []
    end
  end
end
