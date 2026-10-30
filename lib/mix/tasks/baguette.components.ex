defmodule Mix.Tasks.Baguette.Components do
  @shortdoc "Writes the native component sets' manifests"
  @moduledoc """
  Writes one manifest per native component set the host can be built with,
  as `<set>.json`, for `Baguette.Components`:

      mix baguette.components                  # every set, into priv/components
      mix baguette.components gpui-kit         # one set
      mix baguette.components --out some/dir

  A set is a `components-<set>` Cargo feature of `baguette_host`. Each
  manifest comes from a host built with only that set (`baguette_host
  --manifest <set>`).
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, sets} = OptionParser.parse!(args, strict: [out: :string])
    out = Path.expand(opts[:out] || "priv/components")
    native = Path.join(baguette_root(), "native")

    sets =
      if sets == [] do
        {json, 0} = System.cmd("cargo", ~w(metadata --no-deps --format-version 1), cd: native)
        sets(JSON.decode!(json))
      else
        sets
      end

    File.mkdir_p!(out)

    for set <- sets do
      Mix.shell().info([:green, "* manifest ", :reset, set])

      {manifest, 0} =
        System.cmd(
          "cargo",
          ~w(run -q -p baguette_host --no-default-features --features) ++
            ["components-#{set}", "--", "--manifest", set],
          cd: native
        )

      path = Path.join(out, "#{set}.json")
      File.write!(path, manifest)
      Mix.shell().info([:green, "* wrote ", :reset, Path.relative_to_cwd(path)])
    end
  end

  @doc "The component sets among `baguette_host`'s features in `cargo metadata`."
  @spec sets(map()) :: [String.t()]
  def sets(%{"packages" => packages}) do
    for %{"name" => "baguette_host", "features" => features} <- packages,
        "components-" <> set <- Enum.sort(Map.keys(features)),
        do: set
  end

  defp baguette_root, do: Mix.Project.deps_paths()[:baguette] || File.cwd!()
end
