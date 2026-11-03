defmodule Baguette.Release.IosNifs do
  @moduledoc """
  Builds a release's dependency NIFs for iOS, for `Baguette.Release.ios/1`.

  iOS loads no code but the app's own, so each NIF is built as a static
  archive and linked into the app, and the BEAM finds it in its static NIF
  table by module (`erts_static_nif_tab`, which the host's `build.rs`
  generates). Each archive exports `<name>_nif_init`:

    * A dependency with a Cargo crate under `native/` is a Rustler NIF:
      `cargo rustc --release --target <triple> --crate-type staticlib` in the
      crate (so its `rust-toolchain.toml` applies). Rustler 0.37 and later
      name the init function after the crate; earlier versions all export
      `nif_init`, which can't be linked twice, so they are refused.
    * A dependency with a Makefile is an `elixir_make` NIF: its `make`, with
      `CC` and `CXX` set to a wrapper around Xcode's clang
      (`priv/ios/nif-cc`). It compiles with
      `-DSTATIC_ERLANG_NIF_LIBNAME=<name>`, so `ERL_NIF_INIT` emits
      `<name>_nif_init`, and turns the Makefile's shared-library link into a
      relocatable object, which is archived as `lib<name>.a`. `<name>` is the
      NIF file's (`sqlite3_nif` for `priv/sqlite3_nif.so`).

  Builds are kept in `<out>/<triple>/<app>-<vsn>/`, so a second release (or a
  CI cache of that directory) skips them.

  Each dependency can be skipped or tuned with the release's `ios_nifs`
  option, as `android_nifs` is for Android:

      baguette: [ios_nifs: [exqlite: false, explorer: [args: ["--features", "x"], env: [{"K", "v"}]]]]

  A skipped NIF's module fails to load on iOS.
  """

  alias Baguette.Release.AndroidNifs

  @typedoc "How to build one dependency's NIFs, and the archives it leaves."
  @type build :: %{
          app: String.t(),
          vsn: String.t(),
          kind: :rustler | :make,
          cd: String.t(),
          commands: [{String.t(), [String.t()]}],
          env: [{String.t(), String.t()}],
          cache: String.t(),
          outputs: [{String.t(), String.t()}]
        }

  @doc """
  Plans the builds for `nifs` (from `AndroidNifs.find/1`) on one target
  triple.

  `opts`:

    * `:deps` - each dependency's source directory, by app name
    * `:sdk` - `iphoneos` or `iphonesimulator`
    * `:cc` - the compiler wrapper, Baguette's `priv/ios/nif-cc`
    * `:min_version` - the iOS version to build for (`15.0`)
    * `:erts_include` - the ERTS headers
    * `:out` - where builds are kept
    * `:overrides` - the release's `ios_nifs` option
    * `:skip` - apps built elsewhere (Baguette's own NIF)
  """
  @spec plan([AndroidNifs.nif()], String.t(), keyword()) :: [build]
  def plan(nifs, triple, opts) do
    overrides = Map.new(opts[:overrides] || [], fn {app, o} -> {to_string(app), o} end)
    skip = Enum.map(opts[:skip] || [], &to_string/1)

    for %{app: app} = nif <- nifs,
        app not in skip,
        override = Map.get(overrides, app, []),
        override != false do
      dir = Map.get(opts[:deps], app) || raise ArgumentError, "no source for #{app}'s NIF"
      dir = Path.expand(dir)
      cache = Path.join([opts[:out], triple, "#{app}-#{nif.vsn}"])
      build = plan_one(nif, dir, triple, cache, opts)

      %{
        build
        | commands: add_args(build.commands, override[:args] || []),
          env: build.env ++ (override[:env] || [])
      }
    end
  end

  defp plan_one(nif, dir, triple, cache, opts) do
    cond do
      crates(dir) != [] -> plan_rustler(nif, dir, triple, cache, opts)
      File.regular?(Path.join(dir, "Makefile")) -> plan_make(nif, dir, triple, cache, opts)
      true -> raise ArgumentError, "don't know how to build #{nif.app}'s NIF for iOS"
    end
  end

  defp plan_rustler(nif, dir, triple, cache, opts) do
    by_name = Map.new(crates(dir), &{crate_name(&1), &1})
    target_dir = Path.join([opts[:out], "target", nif.app])
    crates = nif.files |> Enum.map(&crate_for!(nif, &1, by_name)) |> Enum.uniq()
    cd = hd(crates)
    Enum.each(crates, &check_rustler!(nif, &1))

    builds =
      for crate <- crates do
        {"cargo",
         ["rustc", "--release", "--lib", "--target", triple, "--target-dir", target_dir] ++
           ["--manifest-path", Path.join(crate, "Cargo.toml"), "--crate-type", "staticlib"]}
      end

    toolchain =
      if Enum.any?(["rust-toolchain.toml", "rust-toolchain"], &File.regular?(Path.join(cd, &1))),
        do: [{"rustup", ["toolchain", "install"]}],
        else: []

    %{
      app: nif.app,
      vsn: nif.vsn,
      kind: :rustler,
      cd: cd,
      commands: toolchain ++ [{"rustup", ["target", "add", triple]}] ++ builds,
      env: [{"IPHONEOS_DEPLOYMENT_TARGET", min_version(opts)}],
      cache: cache,
      outputs:
        for crate <- crates do
          name = crate_name(crate)
          {Path.join([target_dir, triple, "release", "lib#{name}.a"]), name}
        end
    }
  end

  defp plan_make(nif, dir, _triple, cache, opts) do
    scratch = Path.join(cache, "build")
    cc = opts[:cc]

    names = Enum.map(nif.files, &AndroidNifs.lib_name/1)

    if length(names) > 1,
      do: raise(ArgumentError, "#{nif.app} builds several NIFs; iOS takes one per Makefile")

    [name] = names
    [file] = nif.files

    %{
      app: nif.app,
      vsn: nif.vsn,
      kind: :make,
      cd: dir,
      commands: [
        {"make", []},
        {"xcrun", ["ar", "rcs", Path.join(scratch, "lib#{name}.a"), Path.join(scratch, file)]}
      ],
      env: [
        {"CC", cc},
        {"CXX", cc <> "++"},
        {"BAGUETTE_NIF_CC_SDK", opts[:sdk]},
        {"BAGUETTE_NIF_CC_MIN", min_version(opts)},
        {"BAGUETTE_NIF_CC_NAME", name},
        {"ERTS_INCLUDE_DIR", opts[:erts_include]},
        {"MIX_APP_PATH", scratch},
        {"CC_PRECOMPILER_CURRENT_TARGET", "aarch64-apple-ios"}
      ],
      cache: cache,
      outputs: [{Path.join(scratch, "lib#{name}.a"), name}]
    }
  end

  defp min_version(opts), do: opts[:min_version] || "15.0"

  defp add_args(commands, []), do: commands

  defp add_args(commands, args) do
    for {cmd, cmd_args} <- commands do
      if cmd in ["cargo", "make"], do: {cmd, cmd_args ++ args}, else: {cmd, cmd_args}
    end
  end

  # Rustler before 0.37 names every init function `nif_init`.
  defp check_rustler!(nif, crate) do
    lock = [Path.join(crate, "Cargo.lock"), Path.join(crate, "../Cargo.lock")]

    version =
      Enum.find_value(lock, fn path ->
        with {:ok, text} <- File.read(path),
             [_, vsn] <- Regex.run(~r/name = "rustler"\nversion = "([^"]+)"/, text),
             do: vsn,
             else: (_ -> nil)
      end)

    if version && Version.compare(version, "0.37.0") == :lt do
      raise ArgumentError,
            "#{nif.app}'s NIF uses Rustler #{version}; iOS needs 0.37 or later " <>
              "(earlier versions can't be linked beside another NIF)"
    end
  end

  defp crates(dir) do
    dir
    |> Path.join("native/*/Cargo.toml")
    |> Path.wildcard()
    |> Enum.map(&Path.dirname/1)
    |> Enum.sort()
  end

  defp crate_for!(nif, file, by_name) do
    case {Map.get(by_name, AndroidNifs.lib_name(file)), Map.values(by_name)} do
      {crate, _} when is_binary(crate) -> crate
      {nil, [crate]} -> crate
      _ -> raise ArgumentError, "no crate in #{nif.app}/native builds #{file}"
    end
  end

  # The crate's library name: `[lib] name`, else the package name, which is
  # also its `CARGO_CRATE_NAME` and so its init function's prefix.
  defp crate_name(crate) do
    toml = File.read!(Path.join(crate, "Cargo.toml"))

    section = fn name ->
      Regex.run(~r/^\[#{name}\]\s*\n(?:(?!\[).*\n)*?name\s*=\s*"([^"]+)"/m, toml)
    end

    case section.("lib") || section.("package") do
      [_, name] -> String.replace(name, "-", "_")
      nil -> Path.basename(crate)
    end
  end

  @doc """
  Runs `builds`, skipping any whose archives are already kept, and copies
  each archive into `dir` as `lib<name>.a`. Returns the NIFs' names, whose
  `<name>_nif_init` functions go in the static NIF table. `run` runs one
  command: `run.(dir, cmd, args, env)`.
  """
  @spec build!([build], String.t(), (String.t(), String.t(), [String.t()], list() -> :ok)) ::
          [String.t()]
  def build!(builds, dir, run) do
    File.mkdir_p!(dir)

    for build <- builds, {built, name} <- outputs!(build, run) do
      File.cp!(built, Path.join(dir, "lib#{name}.a"))
      name
    end
  end

  defp outputs!(build, run) do
    kept = for {_, name} <- build.outputs, do: {Path.join(build.cache, "lib#{name}.a"), name}

    unless Enum.all?(kept, fn {path, _} -> File.regular?(path) end) do
      File.mkdir_p!(build.cache)
      Enum.each(build.commands, fn {cmd, args} -> run.(build.cd, cmd, args, build.env) end)

      for {built, name} <- build.outputs do
        File.regular?(built) || Mix.raise("#{build.app}'s NIF build left no #{built}")
        File.cp!(built, Path.join(build.cache, "lib#{name}.a"))
      end
    end

    kept
  end
end
