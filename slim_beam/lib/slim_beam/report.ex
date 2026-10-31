defmodule SlimBeam.Report do
  @moduledoc """
  The size of a release before and after slimming, and what was removed and
  why, written to `releases/<vsn>/slim_beam.json`:

      {
        "before": {"total": 41000000, "erts": ..., "lib": ..., "releases": ...,
                   "bin": ..., "apps": {"my_dep": ...}},
        "after": {...},
        "removed": [{"path": "lib/my_dep-1.0.0/ebin/Elixir.MyDep.Unused.beam",
                     "bytes": 1234, "reason": "unreachable"}]
      }

  A reason is `"unreachable"` for a purged module, `"erts"` for the ERTS
  trim and `"prune: <glob>"` for a pruned file.
  """

  alias SlimBeam.Files

  @doc "Bytes in the release at `root`: in all, per top-level directory and per app."
  @spec sizes(Path.t()) :: map()
  def sizes(root) do
    erts = root |> Path.join("erts-*") |> Path.wildcard() |> Enum.map(&Files.size/1) |> Enum.sum()

    apps =
      for dir <- Path.wildcard(Path.join(root, "lib/*")), File.dir?(dir), into: %{} do
        {dir |> Path.basename() |> String.replace(~r/-[^-]*$/, ""), Files.size(dir)}
      end

    %{
      total: Files.size(root),
      erts: erts,
      lib: Files.size(Path.join(root, "lib")),
      releases: Files.size(Path.join(root, "releases")),
      bin: Files.size(Path.join(root, "bin")),
      apps: apps
    }
  end

  @doc "Writes the report to `path`."
  @spec write!(Path.t(), map(), map(), [map()]) :: :ok
  def write!(path, before, after_, removed) do
    File.write!(path, JSON.encode!(%{before: before, after: after_, removed: removed}))
  end

  @doc "Bytes for people."
  @spec format_bytes(non_neg_integer()) :: String.t()
  def format_bytes(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  def format_bytes(bytes) when bytes >= 1_000, do: "#{Float.round(bytes / 1_000, 1)} kB"
  def format_bytes(bytes), do: "#{bytes} B"
end
