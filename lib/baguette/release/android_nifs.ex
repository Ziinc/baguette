defmodule Baguette.Release.AndroidNifs do
  @moduledoc """
  Cross-builds a release's dependency NIFs for Android, for
  `Baguette.Release.android/1`.

  A release built on the desktop carries each NIF for the build machine: a
  Rustler NIF in `priv/native/<stem>.so` (precompiled or not) and an
  `elixir_make` NIF wherever its Makefile puts it, usually `priv/<stem>.so`.
  For every such file this module builds the dependency again for the
  Android ABI and returns it as `lib<name>.so` (`jni_name/1`), the name the
  host links the file to on first launch.

    * A dependency with a Cargo crate under `native/` is a Rustler NIF:
      `cargo build --release --target <triple>` in the crate (so its
      `rust-toolchain.toml` applies) with the NDK's clang as linker and C
      compiler. Rustler before 0.38 finds the BEAM's `enif_*` functions in
      the main program, which on Android is not the BEAM, so its source is
      patched to read `RUSTLER_BEAM_LIBRARY_PATH` as 0.38 does.
    * A dependency with a Makefile is an `elixir_make` NIF: `make` with the
      NDK's clang as `CC`, the ERTS headers in `ERTS_INCLUDE_DIR`,
      `MIX_APP_PATH` pointing at a scratch directory and
      `CC_PRECOMPILER_CURRENT_TARGET` set to the triple. It links against
      `liberlang.so`, since Android resolves a library's symbols only from
      what it links.

  Builds are kept in `<out>/<triple>/<app>-<vsn>/`, so a second release (or a
  CI cache of that directory) skips them.

  Each dependency can be skipped or tuned with the release's `android_nifs`
  option:

      baguette: [android_nifs: [exqlite: false, explorer: [args: ["--features", "x"], env: [{"K", "v"}]]]]

  `args` are added to the `cargo build` or `make` command and `env` to its
  environment. `libs` are prebuilt Android libraries the NIF links, shipped
  beside it under their own names (`libduckdb.so`): a file the app carries
  under the same name is the build machine's copy, so it is not built as a
  NIF, and the host links it to the shipped one on first launch. An override
  can also be a function of the target triple, for env and libs that differ
  by ABI:

      android_nifs: [engine: fn triple -> [libs: ["android/\#{triple}/libduckdb.so"]] end]
  """

  @typedoc "A NIF a release carries: its app, version and files under the app."
  @type nif :: %{app: String.t(), vsn: String.t(), files: [String.t()]}

  @typedoc "How to build one dependency's NIFs."
  @type build :: %{
          app: String.t(),
          vsn: String.t(),
          kind: :rustler | :make,
          cd: String.t(),
          commands: [{String.t(), [String.t()]}],
          env: [{String.t(), String.t()}],
          cache: String.t(),
          outputs: [{String.t(), String.t()}],
          libs: [{String.t(), String.t()}],
          patch_rustler: boolean()
        }

  @doc """
  The NIFs a release's `lib` directory carries: each app's `priv/*.so` and
  `priv/native/*.so`, the same files the host links on first launch.
  """
  @spec find(String.t()) :: [nif]
  def find(lib) do
    for dir <- lib |> File.ls!() |> Enum.sort(),
        [app, vsn] <- [String.split(dir, "-", parts: 2)],
        files = nif_files(Path.join(lib, dir)),
        files != [],
        do: %{app: app, vsn: vsn, files: files}
  end

  @doc "A release's NIF files, relative to their app (`priv/native/x.so`)."
  @spec nif_files(String.t()) :: [String.t()]
  def nif_files(app_dir) do
    for sub <- ["priv", "priv/native"],
        file <- app_dir |> Path.join(sub) |> ls(),
        String.ends_with?(file, ".so"),
        File.regular?(Path.join([app_dir, sub, file])),
        do: Path.join(sub, file)
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, files} -> Enum.sort(files)
      _ -> []
    end
  end

  @doc """
  Plans the builds for `nifs` on one target triple.

  `opts`:

    * `:deps` - each dependency's source directory, by app name
    * `:ndk_bin` - the NDK's `toolchains/llvm/prebuilt/<host>/bin`
    * `:api` - the Android API level the NDK compiles for (24)
    * `:liberlang` - the directory holding this triple's `liberlang.so`
    * `:erts_include` - the ERTS headers
    * `:out` - where builds are kept
    * `:overrides` - the release's `android_nifs` option
    * `:skip` - apps built elsewhere (Baguette's own NIF)
  """
  @spec plan([nif], String.t(), keyword()) :: [build]
  def plan(nifs, triple, opts) do
    overrides = Map.new(opts[:overrides] || [], fn {app, o} -> {to_string(app), o} end)
    skip = Enum.map(opts[:skip] || [], &to_string/1)

    for %{app: app} = nif <- nifs,
        app not in skip,
        override = override(Map.get(overrides, app, []), triple),
        override != false do
      dir = Map.get(opts[:deps], app) || raise ArgumentError, "no source for #{app}'s NIF"
      dir = Path.expand(dir)
      cache = Path.join([opts[:out], triple, "#{app}-#{nif.vsn}"])
      libs = for lib <- override[:libs] || [], do: {lib, Path.basename(lib)}
      shipped = for {_, name} <- libs, do: name
      nif = %{nif | files: Enum.reject(nif.files, &(jni_name(&1) in shipped))}

      build =
        if nif.files == [],
          do: %{
            app: app,
            vsn: nif.vsn,
            kind: :rustler,
            cd: dir,
            commands: [],
            env: [],
            cache: cache,
            outputs: [],
            patch_rustler: false
          },
          else: plan_one(nif, dir, triple, cache, opts)

      Map.merge(build, %{
        commands: add_args(build.commands, override[:args] || []),
        env: build.env ++ (override[:env] || []),
        libs: libs
      })
    end
  end

  defp override(fun, triple) when is_function(fun, 1), do: fun.(triple)
  defp override(override, _triple), do: override

  defp plan_one(nif, dir, triple, cache, opts) do
    cond do
      crates(dir) != [] -> plan_rustler(nif, dir, triple, cache, opts)
      File.regular?(Path.join(dir, "Makefile")) -> plan_make(nif, dir, triple, cache, opts)
      true -> raise ArgumentError, "don't know how to build #{nif.app}'s NIF for Android"
    end
  end

  defp plan_rustler(nif, dir, triple, cache, opts) do
    by_name = Map.new(crates(dir), &{crate_name(&1), &1})
    target_dir = Path.join([opts[:out], "target", nif.app])
    crates = Enum.map(nif.files, &crate_for!(nif, &1, by_name))
    cd = hd(crates)

    builds =
      for crate <- Enum.uniq(crates) do
        {"cargo",
         ["build", "--release", "--target", triple, "--target-dir", target_dir] ++
           ["--manifest-path", Path.join(crate, "Cargo.toml")]}
      end

    toolchain =
      if Enum.any?(["rust-toolchain.toml", "rust-toolchain"], &File.regular?(Path.join(cd, &1))),
        do: [{"rustup", ["toolchain", "install"]}],
        else: []

    under = String.replace(triple, "-", "_")
    upper = String.upcase(under)
    clang = clang(opts, triple)

    %{
      app: nif.app,
      vsn: nif.vsn,
      kind: :rustler,
      cd: cd,
      commands: toolchain ++ [{"rustup", ["target", "add", triple]}] ++ builds,
      env: [
        {"CARGO_TARGET_#{upper}_LINKER", clang},
        {"CC_#{under}", clang},
        {"CXX_#{under}", clang <> "++"},
        {"AR_#{under}", Path.join(opts[:ndk_bin], "llvm-ar")},
        {"RANLIB_#{under}", Path.join(opts[:ndk_bin], "llvm-ranlib")}
      ],
      cache: cache,
      outputs:
        for {file, crate} <- Enum.zip(nif.files, crates) do
          built = Path.join([target_dir, triple, "release", "lib#{crate_name(crate)}.so"])
          {built, jni_name(file)}
        end,
      patch_rustler: true
    }
  end

  defp plan_make(nif, dir, triple, cache, opts) do
    scratch = Path.join(cache, "build")
    ndk = opts[:ndk_bin]
    clang = clang(opts, triple)

    %{
      app: nif.app,
      vsn: nif.vsn,
      kind: :make,
      cd: dir,
      commands: [{"make", []}],
      env: [
        {"CC", clang},
        {"CXX", clang <> "++"},
        {"AR", Path.join(ndk, "llvm-ar")},
        {"RANLIB", Path.join(ndk, "llvm-ranlib")},
        {"LDFLAGS", "-L#{opts[:liberlang]} -l:liberlang.so"},
        {"ERTS_INCLUDE_DIR", opts[:erts_include]},
        {"MIX_APP_PATH", scratch},
        {"CC_PRECOMPILER_CURRENT_TARGET", triple}
      ],
      cache: cache,
      outputs: for(file <- nif.files, do: {Path.join(scratch, file), jni_name(file)}),
      patch_rustler: false
    }
  end

  defp add_args(commands, []), do: commands

  defp add_args(commands, args) do
    for {cmd, cmd_args} <- commands do
      if cmd in ["cargo", "make"], do: {cmd, cmd_args ++ args}, else: {cmd, cmd_args}
    end
  end

  defp clang(opts, triple), do: Path.join(opts[:ndk_bin], "#{triple}#{opts[:api] || 24}-clang")

  @doc """
  The name a NIF file ships under in the APK: `lib<name>.so`, from its
  library name (`lib_name/1`), so a precompiled
  `libexplorer-v0.13.0-nif-2.15-x86_64-unknown-linux-gnu.so` ships as
  `libexplorer.so`. The host's `shipped_name` (in `beam.rs`) links the
  release's file to it by the same rule.
  """
  @spec jni_name(String.t()) :: String.t()
  def jni_name(file), do: "lib#{lib_name(file)}.so"

  @doc """
  The Rust library a NIF file comes from: `libexplorer.so` and the
  precompiled `libexplorer-v0.13.0-nif-2.15-<target>.so` both name `explorer`.
  """
  @spec lib_name(String.t()) :: String.t()
  def lib_name(file) do
    file
    |> Path.basename(".so")
    |> String.replace_prefix("lib", "")
    |> String.split(~r/-v\d/, parts: 2)
    |> hd()
  end

  defp crates(dir) do
    dir
    |> Path.join("native/*/Cargo.toml")
    |> Path.wildcard()
    |> Enum.map(&Path.dirname/1)
    |> Enum.sort()
  end

  defp crate_for!(nif, file, by_name) do
    case {Map.get(by_name, lib_name(file)), Map.values(by_name)} do
      {crate, _} when is_binary(crate) -> crate
      {nil, [crate]} -> crate
      _ -> raise ArgumentError, "no crate in #{nif.app}/native builds #{file}"
    end
  end

  # The crate's library name: `[lib] name`, else the package name.
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
  Runs `builds`, skipping any whose outputs are already kept, and copies each
  output into `jni`, with each build's `libs` (afresh every time, as they are
  not built here). `run` runs one command: `run.(dir, cmd, args, env)`.
  """
  @spec build!([build], String.t(), (String.t(), String.t(), [String.t()], list() -> :ok)) ::
          :ok
  def build!(builds, jni, run) do
    for build <- builds do
      for {lib, _} <- build[:libs] || [], not File.regular?(lib) do
        Mix.raise("#{build.app}'s NIF links #{lib}, which does not exist")
      end

      kept = for {_, name} <- build.outputs, do: Path.join(build.cache, name)

      unless Enum.all?(kept, &File.regular?/1) do
        File.mkdir_p!(build.cache)
        run_build(build, run)

        for {built, name} <- build.outputs do
          File.regular?(built) || Mix.raise("#{build.app}'s NIF build left no #{built}")
          File.cp!(built, Path.join(build.cache, name))
        end
      end

      for name <- kept, do: File.cp!(name, Path.join(jni, Path.basename(name)))
      for {lib, name} <- build[:libs] || [], do: File.cp!(lib, Path.join(jni, name))
    end

    :ok
  end

  defp run_build(%{patch_rustler: true} = build, run) do
    lock = Path.join(build.cd, "Cargo.lock")
    saved = File.read(lock)

    try do
      Enum.each(build.commands, fn
        {"cargo", ["build" | _] = args} ->
          triple = Enum.at(args, Enum.find_index(args, &(&1 == "--target")) + 1)
          run.(build.cd, "cargo", ["fetch", "--target", triple], build.env)
          patch = rustler_patch(build)
          run.(build.cd, "cargo", args ++ patch, build.env)

        {cmd, args} ->
          run.(build.cd, cmd, args, build.env)
      end)
    after
      # Patching rewrites the crate's lock file; leave the dependency as it was.
      with {:ok, content} <- saved, do: File.write!(lock, content)
    end
  end

  defp run_build(build, run) do
    Enum.each(build.commands, fn {cmd, args} -> run.(build.cd, cmd, args, build.env) end)
  end

  defp rustler_patch(build) do
    with {:ok, lock} <- File.read(Path.join(build.cd, "Cargo.lock")),
         [_, vsn] <- Regex.run(~r/name = "rustler"\nversion = "([^"]+)"/, lock),
         [source | _] <- Path.wildcard(Path.join(cargo_home(), "registry/src/*/rustler-#{vsn}")),
         filler = File.read!(Path.join(source, "src/sys/nif_filler.rs")),
         {:ok, patched} <- patch_nif_filler(filler) do
      copy = Path.join([build.cache, "patches", "rustler-#{vsn}"])
      File.rm_rf!(copy)
      File.mkdir_p!(Path.dirname(copy))
      File.cp_r!(source, copy)
      File.write!(Path.join(copy, "src/sys/nif_filler.rs"), patched)
      Mix.shell().info([:green, "* patching ", :reset, "rustler #{vsn} for Android"])
      ["--config", ~s(patch.crates-io.rustler.path="#{copy}")]
    else
      _ -> []
    end
  end

  @doc """
  Rustler's `nif_filler.rs`, made to open the library
  `RUSTLER_BEAM_LIBRARY_PATH` names instead of the main program, or
  `:unchanged` when it already does (Rustler 0.38 and later).
  """
  @spec patch_nif_filler(String.t()) :: {:ok, String.t()} | :unchanged
  def patch_nif_filler(source) do
    open = "Library::open(None::<&OsStr>, RTLD_NOW | RTLD_GLOBAL)"

    cond do
      String.contains?(source, "RUSTLER_BEAM_LIBRARY_PATH") ->
        :unchanged

      String.contains?(source, open) ->
        {:ok,
         String.replace(
           source,
           open,
           ~s/Library::open(std::env::var_os("RUSTLER_BEAM_LIBRARY_PATH").filter(|p| !p.is_empty()), RTLD_NOW | RTLD_GLOBAL)/
         )}

      true ->
        :unchanged
    end
  end

  defp cargo_home, do: System.get_env("CARGO_HOME") || Path.expand("~/.cargo")
end
