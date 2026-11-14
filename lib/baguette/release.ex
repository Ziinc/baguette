defmodule Baguette.Release do
  @moduledoc """
  A `mix release` step that turns a release into a runnable Baguette app.

      releases: [
        my_app: [steps: [:assemble, &Baguette.Release.package/1]]
      ]

  The step installs the native host (`native/baguette_host`) as
  `bin/<release>_app`: precompiled when it can be, else built with Cargo
  (see `host_source/2`). Run that executable to start the app; it boots this
  release inside the host on the BEAM it links. Since the host never runs
  `beam.smp` or `erlexec`, the step trims the release's ERTS to the two
  programs that BEAM starts (`trim_erts!/1`), so `bin/<release>` no longer
  works.

  First, on every platform, it removes the code the release can't reach
  (`Baguette.Release.Slim`). Keep modules it can't see with
  `baguette: [keep: [modules: [...], apps: [...]]]`.

  Host Cargo features are a release option:

      my_app: [steps: [...], baguette: [host_features: ["some_feature"]]]

  `BAGUETTE_HOST_FEATURES` (comma separated) adds more for one build, such as
  `playwright` for the end-to-end tests.

  `components: ["gpui-kit"]` chooses the native component sets compiled into
  the host (see `Baguette.Components`). Without it the host has its default
  sets, which is gpui-kit's; `components: []` leaves them all out.

  `window: [title: "My app", width: 800, height: 600]` sets the main window.

  `cli:` makes the app a command-line tool as well (see `Baguette.CLI`). It
  takes Tauri's CLI plugin schema with snake_case keys, as keywords or maps;
  they are written as `cli` in the release's `baguette.json` with the
  camelCase keys the plugin reads (`takes_value` as `takesValue`,
  `long_description`, `before_help`, `number_of_values`, `possible_values`,
  `required_unless_present`, ...):

      baguette: [
        cli: [
          description: "A counter that can also add numbers",
          subcommands: [
            sum: [
              description: "Prints a + b",
              args: [
                [name: "a", index: 1, takes_value: true, required: true],
                [name: "b", index: 2, takes_value: true, required: true]
              ]
            ]
          ]
        ]
      ]

  With a `cli`, the host opens no window until the app renders to window 0:
  a run that never renders is headless and must end with
  `Baguette.App.exit/1`. Desktop only; on Linux even a headless run needs a
  display.

  The host links a prebuilt BEAM (`liberlang.a`) for the OTP version running
  `mix release`. It is downloaded from Baguette's GitHub releases, checked
  against a pinned SHA-256 and cached under the user cache directory. Set
  `BAGUETTE_LIBERLANG` to a directory holding your own `liberlang.a` (from
  `scripts/build-liberlang.sh`) to skip the download.

  With `BAGUETTE_ANDROID` set, `package/1` and `bundle/1` step aside and
  `android/1` builds an APK instead; with `BAGUETTE_IOS`, `ios/1` builds an
  iOS app.
  """

  alias Baguette.Release.{AndroidNifs, IosNifs, Slim}

  # Baguette's GitHub releases: prebuilt BEAMs, precompiled hosts and NIFs.
  @liberlang_releases "https://github.com/ziinc/baguette/releases/download"

  # The ERTS files the host needs; `trim_erts!/1` keeps only these. On
  # Windows the host loads the release's own BEAM (`beam.smp.dll`), which
  # spawns ports without `erl_child_setup`.
  @erts_programs ["erl_child_setup", "inet_gethost"]
  @erts_programs_windows ["beam.smp.dll", "inet_gethost.exe"]

  @android_abis %{
    "x86_64" => %{triple: "x86_64-linux-android", jni: "x86_64", tauri: "x86_64"},
    "arm64" => %{triple: "aarch64-linux-android", jni: "arm64-v8a", tauri: "aarch64"}
  }

  @ios_targets %{
    "sim" => %{triple: "aarch64-apple-ios-sim", tauri: "aarch64-sim", simulator: true},
    "device" => %{triple: "aarch64-apple-ios", tauri: "aarch64", simulator: false}
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
  `components-<set>` per component set, then `host_features/1`.
  """
  @spec cargo_features(keyword() | map()) :: [String.t()]
  def cargo_features(options) do
    sets = get_in(options, [:baguette, :components])
    features = Enum.map(sets || [], &"components-#{&1}") ++ host_features(options)

    if(sets, do: ["--no-default-features"], else: []) ++
      Enum.flat_map(features, &["--features", &1])
  end

  # The same choice through the Tauri CLI, which passes what follows `--`
  # on to Cargo.
  defp tauri_features(options) do
    case cargo_features(options) do
      ["--no-default-features" | features] -> features ++ ["--", "--no-default-features"]
      features -> features
    end
  end

  @doc """
  Where the release's host comes from:

    * `{:local, path}` - `BAGUETTE_HOST_BINARY`, a host built elsewhere.
    * `:build` - built from source with Cargo, for a component set other
      than the default, any `host_features` (or `BAGUETTE_HOST_FEATURES`),
      or with `BAGUETTE_BUILD_HOST` set.
    * `:precompiled` - downloaded from Baguette's GitHub release for this
      OTP and platform, checked against `priv/host.sha256`. Without a
      pinned checksum (a checkout of an unreleased version) it is built.
  """
  @spec host_source(keyword() | map(), map()) :: :precompiled | :build | {:local, Path.t()}
  def host_source(options, env \\ System.get_env()) do
    features =
      (get_in(options, [:baguette, :host_features]) || []) ++
        String.split(env["BAGUETTE_HOST_FEATURES"] || "", ",", trim: true)

    cond do
      path = env["BAGUETTE_HOST_BINARY"] -> {:local, path}
      env["BAGUETTE_BUILD_HOST"] in ["1", "true"] -> :build
      features != [] -> :build
      get_in(options, [:baguette, :components]) not in [nil, ["gpui-kit"]] -> :build
      true -> :precompiled
    end
  end

  @doc "The precompiled host's asset in Baguette's GitHub release."
  @spec host_asset(String.t(), String.t(), String.t()) :: String.t()
  def host_asset(version, otp, target),
    do: "baguette_host-v#{version}-OTP-#{otp}-#{target}.tar.gz"

  @doc """
  Trims the ERTS of the release at `root` to what the host needs. The host
  links the BEAM, so of ERTS it starts only `erl_child_setup` (at boot) and
  `inet_gethost` (for DNS). `beam.smp`, `erlexec`, the other programs and
  the `include`, `lib`, `doc` and `man` directories go, which also means
  the release's own `bin/<name>` can no longer start it. On Windows the host
  loads the BEAM from `beam.smp.dll` instead of linking it, so that and
  `inet_gethost.exe` stay (`os` is `:os.type/0`).
  """
  @spec trim_erts!(Path.t(), tuple()) :: :ok
  def trim_erts!(root, os \\ :os.type()) do
    keep = if match?({:win32, _}, os), do: @erts_programs_windows, else: @erts_programs

    for erts <- Path.wildcard(Path.join(root, "erts-*")) do
      bin = Path.join(erts, "bin")

      for file <- File.ls!(bin), file not in keep, do: File.rm_rf!(Path.join(bin, file))

      for dir <- File.ls!(erts), dir != "bin", do: File.rm_rf!(Path.join(erts, dir))
    end

    :ok
  end

  @spec package(Mix.Release.t()) :: Mix.Release.t()
  def package(%Mix.Release{} = release) do
    release = Slim.run(release)
    if mobile?(), do: release, else: package_desktop(release)
  end

  defp package_desktop(release) do
    host = desktop_host!(release)

    File.write!(
      Path.join([release.version_path, "baguette.json"]),
      :json.encode(baguette_json(release.options))
    )

    trim_erts!(release.path)

    target = Path.join([release.path, "bin", "#{release.name}_app#{exe()}"])
    levain_pack!(["install", host, target])
    release
  end

  @doc false
  # What `baguette.json` holds: the main window, and the `cli` when declared.
  @spec baguette_json(keyword() | map()) :: map()
  def baguette_json(options) do
    json = %{window: Map.new(get_in(options, [:baguette, :window]) || [])}

    case get_in(options, [:baguette, :cli]) do
      nil -> json
      cli -> Map.put(json, :cli, cli_config(cli))
    end
  end

  @doc false
  # The `cli` option in Tauri's CLI plugin schema: keys (of a command and of
  # its args) as camelCase strings, subcommand names as strings, atoms and
  # tuples as strings and lists, nils dropped.
  @spec cli_config(keyword() | map()) :: map()
  def cli_config(config) do
    for {key, value} <- config, value != nil, into: %{} do
      {camelize(key), cli_value(to_string(key), value)}
    end
  end

  defp cli_value(key, subcommands) when key == "subcommands" do
    Map.new(subcommands, fn {name, config} -> {to_string(name), cli_config(config)} end)
  end

  defp cli_value("args", args), do: Enum.map(args, &cli_config/1)
  defp cli_value(_key, value), do: cli_leaf(value)

  defp cli_leaf(value) when is_boolean(value) or is_number(value), do: value
  defp cli_leaf(value) when is_atom(value), do: Atom.to_string(value)
  defp cli_leaf(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&cli_leaf/1)
  defp cli_leaf(value) when is_list(value), do: Enum.map(value, &cli_leaf/1)
  defp cli_leaf(value), do: value

  defp camelize(key) do
    [first | rest] = key |> to_string() |> String.split("_")
    first <> Enum.map_join(rest, &String.capitalize/1)
  end

  # The host executable for this release, from wherever `host_source/2` says.
  defp desktop_host!(release) do
    source =
      case host_source(release.options) do
        :precompiled ->
          if Map.has_key?(
               host_sha256(),
               host_asset(baguette_version(), otp_version(), desktop_target())
             ),
             do: :precompiled,
             else: :build

        other ->
          other
      end

    case source do
      :precompiled ->
        Mix.shell().info([:green, "* downloading ", :reset, "the precompiled host"])
        host = fetch_asset!(host_asset(baguette_version(), otp_version(), desktop_target()))
        Path.join(host, "baguette_host#{exe()}")

      {:local, path} ->
        path

      :build ->
        build_host!(release)
    end
  end

  defp build_host!(release) do
    native = Path.join(baguette_root(), "native")
    features = cargo_features(release.options)
    target_dir = target_dir(native, features)

    Mix.shell().info([:green, "* building ", :reset, "baguette_host"])

    {_, 0} =
      System.cmd(
        "cargo",
        ["build", "--release", "-p", "baguette_host", "--target-dir", target_dir] ++ features,
        cd: native,
        env: liberlang_env(),
        into: IO.stream()
      )

    Path.join([target_dir, "release", "baguette_host#{exe()}"])
  end

  # Checksums of the precompiled hosts, from the host workflow's summary.
  defp host_sha256, do: sha256_file("priv/host.sha256")

  # Downloads, checks and unpacks a Baguette release asset into the user
  # cache, once, and returns the directory (`levain-pack fetch`).
  defp fetch_asset!(asset) do
    levain_pack!(
      [
        "fetch",
        "#{@liberlang_releases}/v#{baguette_version()}",
        asset,
        "--sha256",
        Path.join(baguette_root(), "priv/host.sha256"),
        "--cache",
        Path.join(:filename.basedir(:user_cache, "baguette"), "assets")
      ],
      capture: true
    )
  end

  defp baguette_version do
    case Application.spec(:baguette, :vsn) do
      nil -> Baguette.version()
      vsn -> List.to_string(vsn)
    end
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
  Tauri CLI's `bundle` through `npx` on the host `package/1` installed, so
  Node must be installed but nothing is compiled again.

  Baguette signs nothing itself. The Tauri CLI inherits the build's
  environment, so set the variables Tauri reads for signing when running the
  final `mix release`: `APPLE_CERTIFICATE`, `APPLE_SIGNING_IDENTITY` and the
  other `APPLE_*` variables on macOS, or on Windows `TAURI_CONFIG` with a
  `bundle.windows` signing configuration (`certificateThumbprint` or
  `signCommand`), which Tauri merges into the bundle's configuration.
  """
  @spec bundle(Mix.Release.t()) :: Mix.Release.t()
  def bundle(%Mix.Release{} = release) do
    options = release.options[:baguette] || []

    bundles =
      cond do
        mobile?() -> []
        env = System.get_env("BAGUETTE_BUNDLES") -> String.split(env, ",", trim: true)
        true -> options[:bundles] || []
      end

    if bundles == [], do: release, else: bundle(release, options, bundles)
  end

  defp bundle(release, options, bundles) do
    native = Path.join(baguette_root(), "native")
    name = Atom.to_string(release.name)
    erts = "erts-#{release.erts_version}"

    resources =
      for dir <- [erts, "lib", "releases"], into: %{} do
        {Path.join(release.path, dir) <> "/", "release/#{dir}/"}
      end

    out = Path.join(Mix.Project.build_path(), "bundle")
    host = Path.join([release.path, "bin", "#{name}_app#{exe()}"])

    # The host `package/1` installed, however it came, is bundled as it is:
    # nothing is compiled again.
    levain_pack!(
      [
        "bundle",
        "--project",
        Path.join(native, "baguette_host"),
        "--host",
        host,
        "--host-name",
        "baguette_host",
        "--name",
        name,
        "--version",
        release.version,
        "--identifier",
        options[:identifier] || "dev.baguette.#{name}",
        "--bundles",
        Enum.join(bundles, ","),
        "--target-dir",
        Path.join(Mix.Project.build_path(), "baguette_host"),
        "--out",
        out
      ] ++
        Enum.flat_map(resources, fn {from, to} -> ["--resource", "#{from}=#{to}"] end) ++
        user_tauri_config()
    )

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

    liberlang = mobile_liberlang!(Enum.map(abis, & &1.triple))

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

    env = [
      {"BAGUETTE_LIBERLANG", liberlang},
      {"LEVAIN_APP_ARCHIVE", archive},
      {"CARGO_TARGET_DIR", Path.join([baguette_root(), "native", "target", "android"])}
    ]

    signed? = System.get_env("BAGUETTE_ANDROID_KEYSTORE") not in [nil, ""]

    levain_pack!(
      ["init", "android", "--project", host, "--config", config] ++
        if(signed?, do: ["--signing-env", "BAGUETTE_ANDROID"], else: []) ++ env_args(env)
    )

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

    File.rm(Path.join(out, "#{name}.aab"))

    products =
      for ext <- if(signed?, do: ["apk", "aab"], else: ["apk"]),
          do: ["--product", "#{ext}=#{Path.join(out, "#{name}.#{ext}")}"]

    levain_pack!(
      ["build", "android", "--project", host, "--config", config] ++
        List.flatten(products) ++
        env_args(env) ++
        ["--"] ++
        if(signed?, do: ["--apk", "--aab"], else: ["--debug", "--apk"]) ++
        Enum.flat_map(abis, &["--target", &1.tauri]) ++
        tauri_features(release.options)
    )

    release
  end

  @doc """
  A `mix release` step that builds an iOS app when `BAGUETTE_IOS` names
  where it runs: `sim` (the simulator on an Apple silicon Mac) or `device`.

      BAGUETTE_IOS=sim MIX_ENV=prod mix release

  As on Android, the release (its `lib` and `releases`, not the build
  machine's ERTS) is embedded in the app and unpacked on first launch. iOS
  loads no code but the app's own, so the BEAM (`liberlang.a`) and every NIF
  are linked into it; the release's NIF files are left empty. It runs no
  other programs either: `System.cmd/3`, `:os.cmd/1` and ports to external
  programs fail with `badarg` (see `scripts/build-liberlang-ios.sh`).

  Every NIF is linked in: Baguette's own, and each one the release's
  dependencies carry, built again for iOS as a static archive; see
  `Baguette.Release.IosNifs`, and its `ios_nifs` option. The BEAM is downloaded like the desktop one; a `BAGUETTE_LIBERLANG`
  of your own must hold `<target>/liberlang.a` and `<target>/driver_tab.c`
  from `scripts/build-liberlang-ios.sh`, built with the OTP this release
  was built with. Needs Xcode, `xcodegen`, Rust's iOS targets and Node.

  The simulator build is an unsigned debug build, `_build/<env>/ios/<name>.app`.
  The device build is an optimised `_build/<env>/ios/<name>.ipa`
  (`BAGUETTE_IOS_PROFILE=debug` or `release` chooses for either), unsigned
  unless signing is configured: the Tauri CLI signs it when
  `APPLE_DEVELOPMENT_TEAM` is set, with the identities in the keychain or
  `IOS_CERTIFICATE`, `IOS_CERTIFICATE_PASSWORD` and `IOS_MOBILE_PROVISION`
  (and App Store Connect's `APPLE_API_KEY`, `APPLE_API_ISSUER` and
  `APPLE_API_KEY_PATH` to manage profiles). `BAGUETTE_IOS_EXPORT_METHOD`
  (`app-store-connect`, `release-testing` or `debugging`) chooses how the
  signed archive is exported. The README's iOS section has the details.
  """
  @spec ios(Mix.Release.t()) :: Mix.Release.t()
  def ios(%Mix.Release{} = release) do
    case System.get_env("BAGUETTE_IOS") do
      nil ->
        release

      kind ->
        ios(release, Map.get(@ios_targets, kind) || Mix.raise("BAGUETTE_IOS is sim or device"))
    end
  end

  defp ios(release, target) do
    options = release.options[:baguette] || []
    name = Atom.to_string(release.name)
    project = Path.join([baguette_root(), "native", "baguette_ios"])
    out = Path.join(Mix.Project.build_path(), "ios")
    File.mkdir_p!(out)

    liberlang = mobile_liberlang!([target.triple])

    # Every other NIF the release carries, built as a static archive the host
    # links (see `IosNifs`).
    nifs = Path.join([out, "nifs", target.triple, "link"])
    File.rm_rf!(nifs)

    release.path
    |> Path.join("lib")
    |> AndroidNifs.find()
    |> IosNifs.plan(target.triple,
      deps: nif_sources(),
      sdk: if(target.simulator, do: "iphonesimulator", else: "iphoneos"),
      cc: Path.join(baguette_root(), "priv/ios/nif-cc"),
      erts_include: Path.join([:code.root_dir(), "erts-#{release.erts_version}", "include"]),
      out: Path.join(out, "nifs"),
      overrides: options[:ios_nifs] || [],
      skip: ["baguette"]
    )
    |> IosNifs.build!(nifs, &run!/4)

    archive = Path.join(out, "release.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(archive), archive_files(release.path), [:compressed])

    config = Path.join(out, "tauri.ios.json")

    File.write!(
      config,
      :json.encode(%{
        productName: get_in(options, [:window, :title]) || name,
        version: release.version,
        identifier: options[:identifier] || "dev.baguette.#{name}"
      })
    )

    # Xcode runs Cargo through the Tauri CLI, which passes on only `TAURI_*`
    # and `CARGO_*` variables; the host's build.rs reads both spellings.
    env = [
      {"TAURI_BAGUETTE_LIBERLANG", liberlang},
      {"TAURI_LEVAIN_APP_ARCHIVE", archive},
      {"TAURI_BAGUETTE_IOS_NIFS", nifs},
      {"CARGO_TARGET_DIR", Path.join([baguette_root(), "native", "target", "ios"])}
    ]

    # The app's Rust library carries the BEAM, whose `enif_*` functions only
    # NIFs call (Rustler finds them with `dlsym` in the app's exports):
    # `-export_dynamic` keeps the linker from dead-stripping them. The BEAM
    # also needs libc++, and reading the system's DNS servers libresolv.
    levain_pack!(
      ["init", "ios", "--project", project, "--config", config] ++
        ["--ldflags", "-Wl,-export_dynamic -lc++ -lresolv"] ++ env_args(env)
    )

    ext = if target.simulator, do: "app", else: "ipa"

    levain_pack!(
      ["build", "ios", "--project", project, "--config", config] ++
        ["--product", "#{ext}=#{Path.join(out, "#{name}.#{ext}")}"] ++
        env_args(env) ++
        ["--", "--target", target.tauri] ++
        ios_build_options(target) ++ tauri_features(release.options)
    )

    release
  end

  @doc false
  # The Tauri CLI's options for `target`. The simulator gets a quick unsigned
  # debug build, a device an optimised one (`BAGUETTE_IOS_PROFILE` chooses
  # otherwise), signed by the Tauri CLI when the environment names a
  # development team.
  @spec ios_build_options(map(), map()) :: [String.t()]
  def ios_build_options(target, env \\ System.get_env()) do
    debug =
      case env["BAGUETTE_IOS_PROFILE"] do
        "debug" -> ["--debug"]
        "release" -> []
        _ -> if target.simulator, do: ["--debug"], else: []
      end

    sign =
      if target.simulator or env["APPLE_DEVELOPMENT_TEAM"] in [nil, ""],
        do: ["--no-sign"],
        else: []

    export =
      case env["BAGUETTE_IOS_EXPORT_METHOD"] do
        method when method in [nil, ""] or target.simulator -> []
        method -> ["--export-method", method]
      end

    debug ++ sign ++ export
  end

  defp mobile?, do: System.get_env("BAGUETTE_ANDROID") || System.get_env("BAGUETTE_IOS")

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

  defp run!(dir, command, args, env) do
    Mix.shell().info([:green, "* running ", :reset, Enum.join([command | args], " ")])

    case System.cmd(command, args, cd: dir, env: env, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("#{command} exited with #{status}")
    end
  end

  # The app's own Tauri configuration (signing, say) from `TAURI_CONFIG`, a
  # JSON string or file, merged over Baguette's.
  defp user_tauri_config do
    case System.get_env("TAURI_CONFIG") do
      config when config in [nil, ""] -> []
      config -> ["--config", config]
    end
  end

  # The host's BEAM: Windows loads the release's own `beam.smp.dll` at
  # startup, so there is nothing to link.
  defp liberlang_env do
    if windows?(), do: [], else: [{"BAGUETTE_LIBERLANG", desktop_liberlang!()}]
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  defp exe, do: if(windows?(), do: ".exe", else: "")

  defp desktop_liberlang! do
    case System.get_env("BAGUETTE_LIBERLANG") do
      dir when dir not in [nil, ""] ->
        dir

      _ ->
        target = desktop_target()
        Path.join(download_liberlang!([target]), target)
    end
  end

  defp mobile_liberlang!(triples) do
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
      {:win32, _} -> "#{cpu}-windows"
      os -> Mix.raise("no prebuilt BEAM for #{inspect(os)}; set BAGUETTE_LIBERLANG")
    end
  end

  # Downloads and unpacks each target's BEAM into the user cache, returning
  # the directory that holds one subdirectory per target.
  defp download_liberlang!(targets) do
    otp = otp_version()
    root = Path.join([:filename.basedir(:user_cache, "baguette"), "liberlang", otp])
    sums = Path.join(baguette_root(), "priv/liberlang.sha256")

    for target <- targets, not File.dir?(Path.join(root, target)) do
      asset = "liberlang-OTP-#{otp}-#{target}.tar.gz"

      if not Map.has_key?(liberlang_sha256(), asset) do
        Mix.raise(
          "no prebuilt BEAM for OTP #{otp} on #{target}; " <>
            "use a supported OTP or set BAGUETTE_LIBERLANG"
        )
      end

      dir =
        levain_pack!(
          [
            "fetch",
            "#{@liberlang_releases}/liberlang-OTP-#{otp}",
            asset,
            "--sha256",
            sums,
            "--cache",
            Path.join(root, "downloads")
          ],
          capture: true
        )

      File.rename!(dir, Path.join(root, target))
    end

    root
  end

  # `sha256sum` output for every published asset, from the liberlang workflow.
  defp liberlang_sha256, do: sha256_file("priv/liberlang.sha256")

  defp sha256_file(path) do
    for line <- File.read!(Path.join(baguette_root(), path)) |> String.split("\n"),
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

  # `levain-pack`, which packages the host (see levain): `LEVAIN_PACK`, the
  # precompiled one from levain's GitHub release when `priv/levain-pack.sha256`
  # pins it for this platform, or else built with Cargo from the levain
  # revision the host is pinned to.
  defp levain_pack!(args, opts \\ []) do
    pack = levain_pack_path()
    Mix.shell().info([:green, "* running ", :reset, Enum.join(["levain-pack" | args], " ")])

    if opts[:capture] do
      case System.cmd(pack, args, stderr_to_stdout: false) do
        {out, 0} -> String.trim(out)
        {_, status} -> Mix.raise("levain-pack exited with #{status}")
      end
    else
      case System.cmd(pack, args, into: IO.stream(), stderr_to_stdout: true) do
        {_, 0} -> :ok
        {_, status} -> Mix.raise("levain-pack exited with #{status}")
      end
    end
  end

  defp levain_pack_path do
    sums = sha256_file("priv/levain-pack.sha256")

    case levain_pack_source(System.get_env(), sums, desktop_target()) do
      {:local, path} ->
        path

      {:precompiled, url, sha256} ->
        Path.join(download!(url, sha256), "levain-pack#{exe()}")

      :build ->
        {repo, rev} = levain_revision()
        root = Path.join([:filename.basedir(:user_cache, "baguette"), "levain-pack", rev])
        pack = Path.join([root, "bin", "levain-pack#{exe()}"])

        if not File.exists?(pack) do
          Mix.shell().info([:green, "* building ", :reset, "levain-pack #{rev}"])

          {_, 0} =
            System.cmd(
              "cargo",
              ~w(install --locked --git #{repo} --rev #{rev} --root #{root} levain-pack),
              into: IO.stream(),
              stderr_to_stdout: true
            )
        end

        pack
    end
  end

  # levain's GitHub releases, which carry `levain-pack` for each platform.
  @levain_releases "https://github.com/Ziinc/levain/releases/download"

  @doc false
  # Where `levain-pack` comes from: `LEVAIN_PACK` in `env`; else levain's
  # release asset for `target` when `checksums` (`priv/levain-pack.sha256`:
  # `levain-pack-v<levain version>-<target>.tar.gz` lines from that release's
  # SHA256SUMS) pins one; else a build from the pinned levain.
  @spec levain_pack_source(map(), map(), String.t()) ::
          {:local, Path.t()} | {:precompiled, String.t(), String.t()} | :build
  def levain_pack_source(env, checksums, target) do
    suffix = "-#{target}.tar.gz"

    pinned =
      Enum.find_value(checksums, fn {asset, sha256} ->
        with "levain-pack-v" <> rest <- asset,
             true <- String.ends_with?(rest, suffix),
             version = String.replace_suffix(rest, suffix, ""),
             true <- version =~ ~r/^\d+\.\d+\.\d+$/ do
          {:precompiled, "#{@levain_releases}/v#{version}/#{asset}", sha256}
        else
          _ -> nil
        end
      end)

    cond do
      path = env["LEVAIN_PACK"] -> {:local, path}
      pinned -> pinned
      true -> :build
    end
  end

  @doc false
  # The levain repository and revision the host is pinned to.
  @spec levain_revision(String.t()) :: {String.t(), String.t()}
  def levain_revision(
        cargo \\ File.read!(Path.join(baguette_root(), "native/baguette_host/Cargo.toml"))
      ) do
    case Regex.run(~r/^levain = \{ git = "([^"]+)", rev = "([0-9a-f]+)"/m, cargo) do
      [_, repo, rev] -> {repo, rev}
      nil -> Mix.raise("native/baguette_host/Cargo.toml pins no levain revision")
    end
  end

  @doc false
  # `--env NAME=value` for each variable levain-pack passes on.
  @spec env_args(Enumerable.t()) :: [String.t()]
  def env_args(env), do: Enum.flat_map(env, fn {k, v} -> ["--env", "#{k}=#{v}"] end)

  # Downloads `url`, a `.tar.gz` that must match `sha256`, and unpacks it into
  # the user cache, once, returning the directory. Only for `levain-pack`
  # itself: everything else is fetched by it.
  defp download!(url, sha256) do
    asset = Path.basename(url)

    dir =
      Path.join([
        :filename.basedir(:user_cache, "baguette"),
        "assets",
        Path.rootname(asset, ".tar.gz")
      ])

    unless File.dir?(dir) do
      body = http_get!(url)

      if Base.encode16(:crypto.hash(:sha256, body), case: :lower) != sha256,
        do: Mix.raise("#{asset} does not match its pinned SHA-256")

      partial = dir <> ".partial"
      File.rm_rf!(partial)
      File.mkdir_p!(partial)
      :ok = :erl_tar.extract({:binary, body}, [:compressed, cwd: String.to_charlist(partial)])
      File.rename!(partial, dir)
    end

    dir
  end

  defp baguette_root do
    Mix.Project.deps_paths()[:baguette] || File.cwd!()
  end
end
