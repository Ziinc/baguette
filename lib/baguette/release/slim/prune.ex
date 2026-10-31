defmodule Baguette.Release.Slim.Prune do
  @moduledoc false
  # Removes the files and directories that match the default globs and the
  # user's, relative to the release root.

  alias Baguette.Release.Slim.Files

  @defaults ["lib/*/src", "lib/*/include", "lib/*/doc"]

  @doc "The globs pruned by default."
  def defaults, do: @defaults

  @doc "Prunes the release at `root`. Returns the report entries."
  def run(root, globs) do
    for glob <- Enum.uniq(@defaults ++ globs),
        path <- Path.wildcard(Path.join(root, glob)),
        File.exists?(path),
        do: Files.remove!(root, Path.relative_to(path, root), "prune: #{glob}")
  end
end
