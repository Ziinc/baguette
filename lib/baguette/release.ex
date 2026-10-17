defmodule Baguette.Release do
  @moduledoc """
  A `mix release` step that turns a release into a runnable Baguette app.

      releases: [
        my_app: [steps: [:assemble, &Baguette.Release.package/1]]
      ]

  The step builds the native host (`native/baguette_host`) and installs it as
  `bin/<release>_app`. Run that executable to start the app; it boots this
  release inside the host on the BEAM it links.

  Host Cargo features are a release option:

      my_app: [steps: [...], baguette: [host_features: ["some_feature"]]]

  `window: [title: "My app", width: 800, height: 600]` sets the main window.

  The host links `liberlang.a` from `$BAGUETTE_LIBERLANG`. Build the release
  with the OTP that archive came from (`scripts/build-liberlang.sh` installs
  one next to it), so the release's ERTS and the linked BEAM match.

  With `BAGUETTE_ANDROID` set, `package/1` and `bundle/1` step aside and
  `android/1` builds an APK instead.
  """

  @android_abis %{
    "x86_64" => %{triple: "x86_64-linux-android", jni: "x86_64", tauri: "x86_64"},
    "arm64" => %{triple: "aarch64-linux-android", jni: "arm64-v8a", tauri: "aarch64"}
  }

  @spec package(Mix.Release.t()) :: Mix.Release.t()
  def package(%Mix.Release{} = release) do
    if System.get_env("BAGUETTE_ANDROID"), do: release, else: package_desktop(release)
  end

  defp package_desktop(release) do
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

  The step does nothing unless the release lists `bundles:` or
  `BAGUETTE_BUNDLES` is set (`BAGUETTE_BUNDLES=deb,appimage mix release`),
  which wins. Bundles land in `_build/<env>/bundle/<format>/`. It runs the
  Tauri CLI through `npx`, so Node must be installed.
  """
  @spec bundle(Mix.Release.t()) :: Mix.Release.t()
  def bundle(%Mix.Release{} = release) do
    options = release.options[:baguette] || []

    bundles =
      cond do
        System.get_env("BAGUETTE_ANDROID") -> []
        env = System.get_env("BAGUETTE_BUNDLES") -> String.split(env, ",", trim: true)
        true -> options[:bundles] || []
      end

    if bundles == [], do: release, else: bundle(release, options, bundles)
  end

  defp bundle(release, options, bundles) do
    native = Path.join(baguette_root(), "native")
    features = options[:host_features] || []
    target_dir = target_dir(native, features)
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

    # Only the bundles themselves, not the bundler's staging directories.
    for format <- bundles,
        from <- Path.wildcard(Path.join([target_dir, "release", "bundle", format, "#{name}_*"])),
        File.regular?(from) do
      File.mkdir_p!(Path.join(out, format))
      File.cp!(from, Path.join([out, format, Path.basename(from)]))
    end

    Mix.shell().info([:green, "* bundled ", :reset, Path.relative_to_cwd(out)])
    release
  end

  @doc """
  A `mix release` step that builds an Android APK when `BAGUETTE_ANDROID`
  names the ABIs to build (`x86_64`, `arm64`, comma-separated):

      BAGUETTE_ANDROID=x86_64 MIX_ENV=prod mix release

  The release (its `lib` and `releases`, not the build machine's ERTS) is
  embedded in the host library, which unpacks it on first launch. The APK
  also carries the BEAM (`liberlang.so`), its port programs
  (`erl_child_setup`, `inet_gethost`) and Baguette's NIF as native libraries.
  `BAGUETTE_LIBERLANG` must hold `<target>/liberlang.so` and both port
  programs for each ABI, from
  `scripts/build-liberlang-android.sh` with the OTP this release was built
  with. Needs the Android SDK and NDK (`ANDROID_HOME`, `NDK_HOME`), Java and
  Node. The debug-signed APK lands in `_build/<env>/android/<name>.apk`.
  """
  @spec android(Mix.Release.t()) :: Mix.Release.t()
  def android(%Mix.Release{} = release) do
    case System.get_env("BAGUETTE_ANDROID") do
      nil -> release
      abis -> android(release, String.split(abis, ",", trim: true))
    end
  end

  defp android(release, abis) do
    options = release.options[:baguette] || []
    name = Atom.to_string(release.name)
    host = Path.join([baguette_root(), "native", "baguette_host"])
    out = Path.join(Mix.Project.build_path(), "android")
    liberlang = liberlang!()
    File.mkdir_p!(out)

    abis =
      for abi <- abis do
        Map.get(@android_abis, abi) || Mix.raise("unknown Android ABI #{abi} (x86_64 or arm64)")
      end

    # The release without the build machine's ERTS: the BEAM is liberlang.so.
    archive = Path.join(out, "release.tar.gz")

    files =
      for dir <- ["lib", "releases"],
          do: {String.to_charlist(dir), String.to_charlist(Path.join(release.path, dir))}

    :ok = :erl_tar.create(String.to_charlist(archive), files, [:compressed])

    config = Path.join(out, "tauri.android.json")

    File.write!(
      config,
      :json.encode(%{
        productName: get_in(options, [:window, :title]) || name,
        version: release.version,
        identifier: options[:identifier] || "dev.baguette.#{name}",
        build: %{frontendDist: "dist"}
      })
    )

    env = [
      {"BAGUETTE_LIBERLANG", liberlang},
      {"BAGUETTE_RELEASE_ARCHIVE", archive},
      {"CARGO_TARGET_DIR", Path.join([baguette_root(), "native", "target", "android"])}
    ]

    run!(host, "npm", ["install", "--no-audit", "--no-fund"], env)
    File.rm_rf!(Path.join(host, "gen/android"))
    run!(host, "npm", ["run", "tauri", "--", "android", "init", "--ci", "--config", config], env)
    patch_gradle!(Path.join(host, "gen/android/app/build.gradle.kts"))

    # Native libraries the app loads or runs besides the host itself.
    for abi <- abis do
      jni = Path.join([host, "gen/android/app/src/main/jniLibs", abi.jni])
      beam = Path.join(liberlang, abi.triple)
      File.mkdir_p!(jni)
      File.cp!(Path.join(beam, "liberlang.so"), Path.join(jni, "liberlang.so"))
      File.cp!(Path.join(beam, "erl_child_setup"), Path.join(jni, "liberl_child_setup.so"))
      File.cp!(Path.join(beam, "inet_gethost"), Path.join(jni, "libinet_gethost.so"))

      linker_env = [
        {"CARGO_TARGET_#{abi.triple |> String.upcase() |> String.replace("-", "_")}_LINKER",
         ndk_clang(abi.triple)}
      ]

      run!(
        Path.join(baguette_root(), "native"),
        "cargo",
        ["build", "--release", "-p", "baguette_nif", "--target", abi.triple],
        env ++ linker_env
      )

      nif =
        Path.join([
          baguette_root(),
          "native/target/android",
          abi.triple,
          "release/libbaguette_nif.so"
        ])

      File.cp!(nif, Path.join(jni, "libbaguette_nif.so"))
    end

    features = options[:host_features] || []

    run!(
      host,
      "npm",
      ["run", "tauri", "--", "android", "build", "--debug", "--apk", "--ci", "--config", config] ++
        Enum.flat_map(abis, &["--target", &1.tauri]) ++
        Enum.flat_map(features, &["--features", &1]),
      env
    )

    [apk | _] = Path.wildcard(Path.join(host, "gen/android/app/build/outputs/apk/**/*.apk"))
    target = Path.join(out, "#{name}.apk")
    File.cp!(apk, target)
    Mix.shell().info([:green, "* built ", :reset, Path.relative_to_cwd(target)])
    release
  end

  defp ndk_clang(triple) do
    ndk =
      System.get_env("NDK_HOME") || System.get_env("ANDROID_NDK_HOME") ||
        Mix.raise("NDK_HOME is not set")

    host = if match?({:unix, :darwin}, :os.type()), do: "darwin-x86_64", else: "linux-x86_64"
    Path.join([ndk, "toolchains/llvm/prebuilt", host, "bin", "#{triple}24-clang"])
  end

  # Android only runs executables extracted from the APK, so native libraries
  # (erl_child_setup among them) are installed as files, not mapped from it.
  defp patch_gradle!(path) do
    gradle = File.read!(path)

    File.write!(
      path,
      String.replace(
        gradle,
        ~r/^android \{/m,
        "android {\n    packaging { jniLibs { useLegacyPackaging = true } }",
        global: false
      )
    )
  end

  defp run!(dir, command, args, env) do
    Mix.shell().info([:green, "* running ", :reset, Enum.join([command | args], " ")])

    case System.cmd(command, args, cd: dir, env: env, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("#{command} exited with #{status}")
    end
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
