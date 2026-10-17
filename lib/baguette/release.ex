defmodule Baguette.Release do
  @moduledoc """
  A `mix release` step that turns a release into a runnable Baguette app.

      releases: [
        my_app: [steps: [:assemble, &Baguette.Release.package/1]]
      ]

  The step builds the native host (`native/baguette_host`) and installs it as
  `bin/<release>_app`. Run that executable to start the app; it boots this
  release inside the host on the BEAM it links.

  Host features are release options; `bootstrap` adds gpui-bootstrap's
  components as `bs-*` elements:

      my_app: [steps: [...], baguette: [host_features: ["bootstrap"]]]

  `window: [title: "My app", width: 800, height: 600]` sets the main window.

  The host links `liberlang.a` from `$BAGUETTE_LIBERLANG`. Build the release
  with the OTP that archive came from (`scripts/build-liberlang.sh` installs
  one next to it), so the release's ERTS and the linked BEAM match.
  """

  @spec package(Mix.Release.t()) :: Mix.Release.t()
  def package(%Mix.Release{} = release) do
    liberlang = liberlang!()
    native = Path.join(baguette_root(), "native")
    features = get_in(release.options, [:baguette, :host_features]) || []
    target_dir = target_dir(native, features)

    Mix.shell().info([:green, "* building ", :reset, "baguette_host"])

    {_, 0} =
      System.cmd(
        "cargo",
        ["build", "--release", "-p", "baguette_host", "--target-dir", target_dir] ++
          Enum.flat_map(features, &["--features", &1]),
        cd: native,
        env: [{"BAGUETTE_LIBERLANG", liberlang}],
        into: IO.stream()
      )

    window = Map.new(get_in(release.options, [:baguette, :window]) || [])

    File.write!(
      Path.join([release.version_path, "baguette.json"]),
      :json.encode(%{window: window})
    )

    target = Path.join([release.path, "bin", "#{release.name}_app"])
    # Replace rather than overwrite, so a running copy doesn't block the build.
    File.rm(target)
    File.cp!(Path.join([target_dir, "release", "baguette_host"]), target)
    File.chmod!(target, 0o755)
    Mix.shell().info([:green, "* installed ", :reset, Path.relative_to_cwd(target)])
    release
  end

  @doc """
  A `mix release` step, after `package/1`, that bundles the app for
  distribution with the Tauri bundler. Each bundle carries the release in its
  resources, where the host finds it at startup.

      steps: [:assemble, &Baguette.Release.package/1, &Baguette.Release.bundle/1],
      baguette: [bundles: ["deb", "appimage"], identifier: "com.example.my_app"]

  Bundles default to `deb` and `appimage` on Linux and land in
  `_build/<env>/bundle/<format>/`. Runs the Tauri CLI through `npx`, so Node
  must be installed.
  """
  @spec bundle(Mix.Release.t()) :: Mix.Release.t()
  def bundle(%Mix.Release{} = release) do
    options = release.options[:baguette] || []
    native = Path.join(baguette_root(), "native")
    features = options[:host_features] || []
    target_dir = target_dir(native, features)
    bundles = options[:bundles] || ["deb", "appimage"]
    name = Atom.to_string(release.name)
    erts = "erts-#{release.erts_version}"

    resources =
      for dir <- [erts, "lib", "releases"], into: %{} do
        {Path.join(release.path, dir) <> "/", "release/#{dir}/"}
      end

    config = %{
      productName: name,
      mainBinaryName: "#{name}_app",
      version: release.version,
      identifier: options[:identifier] || "dev.baguette.#{name}",
      bundle: %{active: true, targets: bundles, resources: resources}
    }

    config_path = Path.join(release.version_path, "tauri.bundle.json")
    File.write!(config_path, :json.encode(config))
    Mix.shell().info([:green, "* bundling ", :reset, Enum.join(bundles, ", ")])

    {_, 0} =
      System.cmd(
        "npx",
        ["--yes", "@tauri-apps/cli@2", "build", "--config", config_path, "--bundles"] ++
          bundles ++ Enum.flat_map(features, &["--features", &1]),
        cd: Path.join(native, "baguette_host"),
        env: [
          {"BAGUETTE_LIBERLANG", liberlang!()},
          {"CARGO_TARGET_DIR", target_dir},
          {"NO_STRIP", "true"}
        ],
        into: IO.stream()
      )

    out = Path.join(Mix.Project.build_path(), "bundle")

    for format <- bundles do
      from = Path.join([target_dir, "release", "bundle", format])
      File.mkdir_p!(Path.join(out, format))
      File.cp_r!(from, Path.join(out, format))
    end

    Mix.shell().info([:green, "* bundled ", :reset, Path.relative_to_cwd(out)])
    release
  end

  defp liberlang! do
    System.get_env("BAGUETTE_LIBERLANG") || Mix.raise("BAGUETTE_LIBERLANG is not set")
  end

  defp target_dir(native, features) do
    # One target directory per feature set, so demos don't rebuild each other.
    Path.join([native, "target" | Enum.map(features, &"features-#{&1}")])
  end

  defp baguette_root do
    Mix.Project.deps_paths()[:baguette] || File.cwd!()
  end
end
