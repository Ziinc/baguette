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

  `BAGUETTE_HOST_FEATURES` (comma separated) adds more for one build, such as
  `playwright` for the end-to-end tests.

  `components: ["gpui-kit"]` chooses the native component sets compiled into
  the host (see `Baguette.Components`). Without it the host has its default
  sets, which is gpui-kit's; `components: []` leaves them all out.

  The host leaves out the APIs and icons the app's source doesn't use, as
  Tailwind does with classes: see `Baguette.Release.Scan` for `exclude:`,
  `scan:` and `safelist:`.

  `window: [title: "My app", width: 800, height: 600]` sets the main window.

  The host links a prebuilt BEAM (`liberlang.a`) for the OTP version running
  `mix release`. It is downloaded from Baguette's GitHub releases, checked
  against a pinned SHA-256 and cached under the user cache directory. Set
  `BAGUETTE_LIBERLANG` to a directory holding your own `liberlang.a` (from
  `scripts/build-liberlang.sh`) to skip the download.

  With `BAGUETTE_ANDROID` set, `package/1` and `bundle/1` step aside and
  `android/1` builds an APK instead.
  """

  alias Baguette.Release.{AndroidNifs, Scan}

  @android_abis %{
    "x86_64" => %{triple: "x86_64-linux-android", jni: "x86_64", tauri: "x86_64"},
    "arm64" => %{triple: "aarch64-linux-android", jni: "arm64-v8a", tauri: "aarch64"}
  }

  @doc "The host's Cargo features: the release option plus `BAGUETTE_HOST_FEATURES`."
  @spec host_features(keyword() | map()) :: [String.t()]
  def host_features(options) do
    env = String.split(System.get_env("BAGUETTE_HOST_FEATURES", ""), ",", trim: true)

    Enum.uniq(
      (get_in(options, [:baguette, :host_features]) || []) ++ Enum.map(env, &String.trim/1)
    )
  end

  @doc """
  The Cargo arguments that choose the host's features: one
  `components-<set>` per component set, one `api-<name>` per API `plan`
  keeps (`Baguette.Release.Scan`), then `host_features/1`. Without a plan
  it scans the current project.
  """
  @spec cargo_features(keyword() | map(), Scan.plan() | nil) :: [String.t()]
  def cargo_features(options, plan \\ nil) do
    plan = plan || Scan.plan(options, File.cwd!())
    sets = get_in(options, [:baguette, :components])

    if sets == nil and plan.excluded == [] do
      Enum.flat_map(host_features(options), &["--features", &1])
    else
      apis = for api <- Scan.apis(), api not in plan.excluded, do: api_feature(api)

      features =
        Enum.map(sets || ["gpui-kit"], &"components-#{&1}") ++ apis ++ host_features(options)

      ["--no-default-features" | Enum.flat_map(features, &["--features", &1])]
    end
  end

  defp api_feature(api), do: "api-" <> String.replace(Atom.to_string(api), "_", "-")

  @doc """
  Writes the icon names `plan` keeps, one per line, into `dir` for the
  host's build (`BAGUETTE_ICONS_FILE`), and returns the file; `nil` when
  the plan keeps every icon.
  """
  @spec icons_file(Scan.plan(), Path.t()) :: Path.t() | nil
  def icons_file(%{icons: :all}, _dir), do: nil

  def icons_file(%{icons: {:only, icons}}, dir) do
    path = Path.join(dir, "icons.txt")
    File.write!(path, icons |> Enum.sort() |> Enum.map_join(&(&1 <> "\n")))
    path
  end

  # What the host's build reads besides its features.
  defp build_env(release, plan) do
    [{"BAGUETTE_ICONS_FILE", icons_file(plan, release.version_path) || ""}]
  end

  # The same choice through the Tauri CLI, which passes what follows `--`
  # on to Cargo.
  defp tauri_features(options, plan) do
    case cargo_features(options, plan) do
      ["--no-default-features" | features] -> features ++ ["--", "--no-default-features"]
      features -> features
    end
  end

  @spec package(Mix.Release.t()) :: Mix.Release.t()
  def package(%Mix.Release{} = release) do
    if System.get_env("BAGUETTE_ANDROID"), do: release, else: package_desktop(release)
  end

  defp package_desktop(release) do
    liberlang = desktop_liberlang!()
    native = Path.join(baguette_root(), "native")
    plan = Scan.plan(release.options, File.cwd!())
    features = cargo_features(release.options, plan)
    target_dir = target_dir(native, features)

    Mix.shell().info([:green, "* building ", :reset, "baguette_host"])

    {_, 0} =
      System.cmd(
        "cargo",
        ["build", "--release", "-p", "baguette_host", "--target-dir", target_dir] ++ features,
        cd: native,
        env: [{"BAGUETTE_LIBERLANG", liberlang} | build_env(release, plan)],
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
    plan = Scan.plan(release.options, File.cwd!())
    target_dir = target_dir(native, cargo_features(release.options, plan))
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
          bundles ++ tauri_features(release.options, plan),
        cd: Path.join(native, "baguette_host"),
        env: [
          {"BAGUETTE_LIBERLANG", desktop_liberlang!()},
          {"CARGO_TARGET_DIR", target_dir},
          {"BAGUETTE_ICONS_FILE", icons_file(plan, release.version_path) || ""},
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
  They are downloaded like the desktop BEAM; a `BAGUETTE_LIBERLANG` of your
  own must hold `<target>/liberlang.so` and both port programs for each ABI,
  from `scripts/build-liberlang-android.sh` with the OTP this release was
  built with. Needs the Android SDK and NDK (`ANDROID_HOME`, `NDK_HOME`), Java and
  Node.

  Every other NIF the release carries (Rustler crates and `elixir_make`
  Makefiles in its dependencies) is built again for each ABI and shipped the
  same way; see `Baguette.Release.AndroidNifs` for how, and for the
  `android_nifs` option that skips or tunes a dependency's build.

  Without a signing key the step builds a debug-signed APK. With
  `BAGUETTE_ANDROID_KEYSTORE` (a keystore file),
  `BAGUETTE_ANDROID_KEYSTORE_PASSWORD`, `BAGUETTE_ANDROID_KEY_ALIAS` and
  `BAGUETTE_ANDROID_KEY_PASSWORD` set it builds an optimised release, signed
  with that key, as an APK to install and an AAB for Google Play. Both land in
  `_build/<env>/android/` as `<name>.apk` and `<name>.aab`.
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
    File.mkdir_p!(out)

    abis =
      for abi <- abis do
        Map.get(@android_abis, abi) || Mix.raise("unknown Android ABI #{abi} (x86_64 or arm64)")
      end

    liberlang = android_liberlang!(Enum.map(abis, & &1.triple))

    # The release without the build machine's ERTS: the BEAM is liberlang.so.
    archive = Path.join(out, "release.tar.gz")

    :ok = :erl_tar.create(String.to_charlist(archive), archive_files(release.path), [:compressed])

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

    plan = Scan.plan(release.options, File.cwd!())

    env = [
      {"BAGUETTE_ICONS_FILE", icons_file(plan, out) || ""},
      {"BAGUETTE_LIBERLANG", liberlang},
      {"BAGUETTE_RELEASE_ARCHIVE", archive},
      {"CARGO_TARGET_DIR", Path.join([baguette_root(), "native", "target", "android"])}
    ]

    run!(host, "npm", ["install", "--no-audit", "--no-fund"], env)
    File.rm_rf!(Path.join(host, "gen/android"))
    run!(host, "npm", ["run", "tauri", "--", "android", "init", "--ci", "--config", config], env)
    signed? = System.get_env("BAGUETTE_ANDROID_KEYSTORE") not in [nil, ""]
    patch_gradle!(Path.join(host, "gen/android/app/build.gradle.kts"), signed?)

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

      # Every other NIF the release carries, built again for this ABI.
      release.path
      |> Path.join("lib")
      |> AndroidNifs.find()
      |> AndroidNifs.plan(abi.triple,
        deps: nif_sources(),
        ndk_bin: Path.dirname(ndk_clang(abi.triple)),
        liberlang: beam,
        erts_include: Path.join([:code.root_dir(), "erts-#{release.erts_version}", "include"]),
        out: Path.join(out, "nifs"),
        overrides: options[:android_nifs] || [],
        skip: ["baguette"]
      )
      |> AndroidNifs.build!(jni, &run!/4)
    end

    run!(
      host,
      "npm",
      ["run", "tauri", "--", "android", "build", "--ci", "--config", config] ++
        if(signed?, do: ["--apk", "--aab"], else: ["--debug", "--apk"]) ++
        Enum.flat_map(abis, &["--target", &1.tauri]) ++
        tauri_features(release.options, plan),
      env
    )

    outputs = Path.join(host, "gen/android/app/build/outputs")
    File.rm(Path.join(out, "#{name}.aab"))

    for ext <- if(signed?, do: ["apk", "aab"], else: ["apk"]) do
      [built | _] = Path.wildcard(Path.join(outputs, "**/*.#{ext}"))
      target = Path.join(out, "#{name}.#{ext}")
      File.cp!(built, target)
      Mix.shell().info([:green, "* built ", :reset, Path.relative_to_cwd(target)])
    end

    release
  end

  # The release's `lib` and `releases`, with each NIF emptied: the build
  # machine's NIFs are of no use on Android, where the host links each one to
  # its `lib<name>.so` in the APK (`AndroidNifs.jni_name/1`).
  defp archive_files(root) do
    nifs =
      for %{app: app, vsn: vsn, files: files} <- AndroidNifs.find(Path.join(root, "lib")),
          file <- files,
          into: MapSet.new(),
          do: Path.join(["lib", "#{app}-#{vsn}", file])

    for dir <- ["lib", "releases"],
        path <- Path.wildcard(Path.join([root, dir, "**"]), match_dot: true),
        File.regular?(path) do
      name = Path.relative_to(path, root)
      content = if name in nifs, do: <<>>, else: String.to_charlist(path)
      {String.to_charlist(name), content}
    end
  end

  # Each dependency's (and umbrella app's) source, by app name.
  defp nif_sources do
    Map.merge(Mix.Project.apps_paths() || %{}, Mix.Project.deps_paths())
    |> Map.new(fn {app, path} -> {Atom.to_string(app), Path.expand(path)} end)
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
  # A release is signed with the key the BAGUETTE_ANDROID_KEY* variables name.
  defp patch_gradle!(path, signed?) do
    signing = """
        signingConfigs {
            create("release") {
                storeFile = file(System.getenv("BAGUETTE_ANDROID_KEYSTORE"))
                storePassword = System.getenv("BAGUETTE_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("BAGUETTE_ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("BAGUETTE_ANDROID_KEY_PASSWORD")
            }
        }
    """

    gradle =
      path
      |> File.read!()
      |> String.replace(
        ~r/^android \{\n/m,
        "android {\n    packaging { jniLibs { useLegacyPackaging = true } }\n" <>
          if(signed?, do: signing, else: ""),
        global: false
      )

    gradle =
      if signed? do
        String.replace(
          gradle,
          ~s/getByName("release") {\n/,
          ~s/getByName("release") {\n            signingConfig = signingConfigs.getByName("release")\n/,
          global: false
        )
      else
        gradle
      end

    File.write!(path, gradle)
  end

  defp run!(dir, command, args, env) do
    Mix.shell().info([:green, "* running ", :reset, Enum.join([command | args], " ")])

    case System.cmd(command, args, cd: dir, env: env, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("#{command} exited with #{status}")
    end
  end

  @liberlang_releases "https://github.com/ziinc/baguette/releases/download"

  defp desktop_liberlang! do
    case System.get_env("BAGUETTE_LIBERLANG") do
      dir when dir not in [nil, ""] ->
        dir

      _ ->
        target = desktop_target()
        Path.join(download_liberlang!([target]), target)
    end
  end

  defp android_liberlang!(triples) do
    case System.get_env("BAGUETTE_LIBERLANG") do
      dir when dir not in [nil, ""] -> dir
      _ -> download_liberlang!(triples)
    end
  end

  defp desktop_target do
    arch = :erlang.system_info(:system_architecture) |> List.to_string()
    cpu = if String.starts_with?(arch, ["aarch64", "arm64"]), do: "aarch64", else: "x86_64"

    case :os.type() do
      {:unix, :linux} -> "#{cpu}-linux"
      {:unix, :darwin} -> "#{cpu}-macos"
      os -> Mix.raise("no prebuilt BEAM for #{inspect(os)}; set BAGUETTE_LIBERLANG")
    end
  end

  # Downloads and unpacks each target's BEAM into the user cache, returning
  # the directory that holds one subdirectory per target.
  defp download_liberlang!(targets) do
    otp = otp_version()
    root = Path.join([:filename.basedir(:user_cache, "baguette"), "liberlang", otp])

    for target <- targets, not File.dir?(Path.join(root, target)) do
      asset = "liberlang-OTP-#{otp}-#{target}.tar.gz"

      sha256 =
        Map.get(liberlang_sha256(), asset) ||
          Mix.raise(
            "no prebuilt BEAM for OTP #{otp} on #{target}; " <>
              "use a supported OTP or set BAGUETTE_LIBERLANG"
          )

      url = "#{@liberlang_releases}/liberlang-OTP-#{otp}/#{asset}"
      Mix.shell().info([:green, "* downloading ", :reset, url])
      body = http_get!(url)

      if Base.encode16(:crypto.hash(:sha256, body), case: :lower) != sha256 do
        Mix.raise("#{asset} does not match its pinned SHA-256")
      end

      partial = Path.join(root, "#{target}.partial")
      File.rm_rf!(partial)
      File.mkdir_p!(partial)
      :ok = :erl_tar.extract({:binary, body}, [:compressed, cwd: String.to_charlist(partial)])
      File.rename!(partial, Path.join(root, target))
    end

    root
  end

  # `sha256sum` output for every published asset, from the liberlang workflow.
  defp liberlang_sha256 do
    for line <-
          File.read!(Path.join(baguette_root(), "priv/liberlang.sha256")) |> String.split("\n"),
        not String.starts_with?(line, "#"),
        [sha, file] <- [String.split(line, ~r/\s+\*?/, parts: 2, trim: true)],
        into: %{},
        do: {file, sha}
  end

  defp otp_version do
    [:code.root_dir(), "releases", :erlang.system_info(:otp_release), "OTP_VERSION"]
    |> Path.join()
    |> File.read!()
    |> String.trim()
  end

  defp http_get!(url) do
    {:ok, _} = Application.ensure_all_started([:ssl, :inets])

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(:get, {String.to_charlist(url), []}, [ssl: ssl, autoredirect: true],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} -> body
      {:ok, {{_, status, _}, _, _}} -> Mix.raise("GET #{url} returned #{status}")
      {:error, reason} -> Mix.raise("GET #{url} failed: #{inspect(reason)}")
    end
  end

  defp target_dir(native, cargo_args) do
    # One target directory per feature set, so demos don't rebuild each other.
    dirs =
      Enum.flat_map(cargo_args, fn
        "--features" -> []
        "--no-default-features" -> ["no-default-features"]
        feature -> ["features-#{feature}"]
      end)

    Path.join([native, "target" | dirs])
  end

  defp baguette_root do
    Mix.Project.deps_paths()[:baguette] || File.cwd!()
  end
end
