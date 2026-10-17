defmodule Baguette.Release do
  @moduledoc """
  A `mix release` step that turns a release into a runnable Baguette app.

      releases: [
        my_app: [steps: [:assemble, &Baguette.Release.package/1]]
      ]

  The step builds the native host (`native/baguette_host`) and installs it as
  `bin/<release>_app`. Run that executable to start the app; it boots this
  release inside the host on the BEAM it links.

  The host links `liberlang.a` from `$BAGUETTE_LIBERLANG`. Build the release
  with the OTP that archive came from (`scripts/build-liberlang.sh` installs
  one next to it), so the release's ERTS and the linked BEAM match.
  """

  @spec package(Mix.Release.t()) :: Mix.Release.t()
  def package(%Mix.Release{} = release) do
    liberlang = System.get_env("BAGUETTE_LIBERLANG") || Mix.raise("BAGUETTE_LIBERLANG is not set")
    native = Path.join(baguette_root(), "native")

    Mix.shell().info([:green, "* building ", :reset, "baguette_host"])

    {_, 0} =
      System.cmd("cargo", ["build", "--release", "-p", "baguette_host"],
        cd: native,
        env: [{"BAGUETTE_LIBERLANG", liberlang}],
        into: IO.stream()
      )

    target = Path.join([release.path, "bin", "#{release.name}_app"])
    File.cp!(Path.join([native, "target", "release", "baguette_host"]), target)
    File.chmod!(target, 0o755)
    Mix.shell().info([:green, "* installed ", :reset, Path.relative_to_cwd(target)])
    release
  end

  defp baguette_root do
    Mix.Project.deps_paths()[:baguette] || File.cwd!()
  end
end
