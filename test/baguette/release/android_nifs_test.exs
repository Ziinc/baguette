defmodule Baguette.Release.AndroidNifsTest do
  # Not async: one test changes the working directory.
  use ExUnit.Case, async: false
  alias Baguette.Release.AndroidNifs

  @triple "x86_64-linux-android"

  setup %{tmp_dir: tmp} do
    lib = Path.join(tmp, "rel/lib")
    deps = Path.join(tmp, "deps")

    write = fn path, content ->
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    # A precompiled Rustler NIF, an elixir_make NIF, Baguette's own, and an
    # app with none.
    write.(
      Path.join(
        lib,
        "explorer-0.13.0/priv/native/libexplorer-v0.13.0-nif-2.15-x86_64-unknown-linux-gnu.so"
      ),
      "elf"
    )

    write.(Path.join(lib, "exqlite-0.43.0/priv/sqlite3_nif.so"), "elf")
    write.(Path.join(lib, "baguette-0.1.0/priv/native/baguette_nif.so"), "elf")
    write.(Path.join(lib, "jason-1.4.0/ebin/jason.app"), "")

    write.(Path.join(deps, "explorer/native/explorer/Cargo.toml"), """
    [package]
    name = "explorer"
    version = "0.1.0"

    [lib]
    name = "explorer"
    crate-type = ["cdylib"]
    """)

    write.(Path.join(deps, "explorer/native/explorer/rust-toolchain.toml"), "[toolchain]\n")

    write.(
      Path.join(deps, "explorer/native/other/Cargo.toml"),
      "[package]\nname = \"other-crate\"\n"
    )

    write.(Path.join(deps, "exqlite/Makefile"), "all:\n")

    opts = [
      deps: %{"explorer" => Path.join(deps, "explorer"), "exqlite" => Path.join(deps, "exqlite")},
      ndk_bin: "/ndk/bin",
      liberlang: "/beam/#{@triple}",
      erts_include: "/erts/include",
      out: Path.join(tmp, "nifs"),
      skip: [:baguette]
    ]

    %{lib: lib, deps: deps, opts: opts, out: Path.join(tmp, "nifs")}
  end

  @moduletag :tmp_dir

  test "find/1 lists each app's priv/*.so and priv/native/*.so", %{lib: lib} do
    assert AndroidNifs.find(lib) == [
             %{app: "baguette", vsn: "0.1.0", files: ["priv/native/baguette_nif.so"]},
             %{
               app: "explorer",
               vsn: "0.13.0",
               files: ["priv/native/libexplorer-v0.13.0-nif-2.15-x86_64-unknown-linux-gnu.so"]
             },
             %{app: "exqlite", vsn: "0.43.0", files: ["priv/sqlite3_nif.so"]}
           ]
  end

  test "names: lib<stem>.so in the APK, and the Rust library a file comes from" do
    assert AndroidNifs.jni_name("priv/sqlite3_nif.so") == "libsqlite3_nif.so"
    assert AndroidNifs.jni_name("priv/native/libfoo.so") == "libfoo.so"
    assert AndroidNifs.jni_name("priv/native/baguette_nif.so") == "libbaguette_nif.so"

    # A precompiled NIF's name carries its version and the build machine's
    # triple; in the APK it is the library's own name.
    assert AndroidNifs.jni_name(
             "priv/native/libexplorer-v0.13.0-nif-2.15-x86_64-unknown-linux-gnu.so"
           ) == "libexplorer.so"

    assert AndroidNifs.lib_name("libexplorer-v0.13.0-nif-2.15-x86_64-unknown-linux-gnu.so") ==
             "explorer"

    assert AndroidNifs.lib_name("priv/native/libixpipe_sqlite.so") == "ixpipe_sqlite"
  end

  test "a Rustler dep builds its crate with cargo for the triple, with the NDK", ctx do
    [build, _] = AndroidNifs.plan(AndroidNifs.find(ctx.lib), @triple, ctx.opts)
    crate = Path.join(ctx.deps, "explorer/native/explorer")
    target = Path.join(ctx.out, "target/explorer")

    assert %{app: "explorer", kind: :rustler, cd: ^crate, patch_rustler: true} = build

    assert build.commands == [
             {"rustup", ["toolchain", "install"]},
             {"rustup", ["target", "add", @triple]},
             {"cargo",
              ["build", "--release", "--target", @triple, "--target-dir", target] ++
                ["--manifest-path", Path.join(crate, "Cargo.toml")]}
           ]

    assert {"CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER", "/ndk/bin/x86_64-linux-android24-clang"} in build.env
    assert {"CC_x86_64_linux_android", "/ndk/bin/x86_64-linux-android24-clang"} in build.env
    assert {"AR_x86_64_linux_android", "/ndk/bin/llvm-ar"} in build.env

    assert build.outputs == [
             {Path.join(target, "#{@triple}/release/libexplorer.so"), "libexplorer.so"}
           ]

    assert build.cache == Path.join(ctx.out, "#{@triple}/explorer-0.13.0")
  end

  test "an elixir_make dep runs make with the NDK's clang, ERTS headers and liberlang", ctx do
    [_, build] = AndroidNifs.plan(AndroidNifs.find(ctx.lib), @triple, ctx.opts)
    scratch = Path.join(ctx.out, "#{@triple}/exqlite-0.43.0/build")

    assert %{app: "exqlite", kind: :make, commands: [{"make", []}]} = build
    assert build.cd == Path.join(ctx.deps, "exqlite")
    assert {"CC", "/ndk/bin/x86_64-linux-android24-clang"} in build.env
    assert {"ERTS_INCLUDE_DIR", "/erts/include"} in build.env
    assert {"LDFLAGS", "-L/beam/#{@triple} -l:liberlang.so"} in build.env
    assert {"MIX_APP_PATH", scratch} in build.env
    assert {"CC_PRECOMPILER_CURRENT_TARGET", @triple} in build.env
    assert build.outputs == [{Path.join(scratch, "priv/sqlite3_nif.so"), "libsqlite3_nif.so"}]
  end

  test "overrides skip a dep or add args and env", ctx do
    opts =
      Keyword.put(ctx.opts, :overrides,
        exqlite: false,
        explorer: [args: ["--no-default-features"], env: [{"K", "v"}]]
      )

    [build] = AndroidNifs.plan(AndroidNifs.find(ctx.lib), @triple, opts)
    assert build.app == "explorer"
    {"cargo", args} = List.last(build.commands)
    assert List.last(args) == "--no-default-features"
    assert {"rustup", ["target", "add", @triple]} in build.commands
    assert {"K", "v"} in build.env
  end

  # An app whose NIF links a prebuilt library it carries beside itself
  # (priv/native/libduckdb.so, for the build machine).
  defp with_linked_lib(ctx) do
    app = Path.join(ctx.lib, "engine-0.1.0/priv/native")
    File.mkdir_p!(app)
    File.write!(Path.join(app, "libduckdb.so"), "host elf")
    File.write!(Path.join(app, "libengine_nif.so"), "host elf")
    crate = Path.join(ctx.deps, "engine/native/engine_nif")
    File.mkdir_p!(crate)
    File.write!(Path.join(crate, "Cargo.toml"), ~s([package]\nname = "engine_nif"\n))
    nifs = Enum.filter(AndroidNifs.find(ctx.lib), &(&1.app == "engine"))
    opts = Keyword.update!(ctx.opts, :deps, &Map.put(&1, "engine", Path.join(ctx.deps, "engine")))
    {nifs, opts, crate}
  end

  test "libs ship beside a NIF in place of the build machine's copy, which is not built", ctx do
    {nifs, opts, crate} = with_linked_lib(ctx)
    lib = Path.join(ctx.tmp_dir, "android/libduckdb.so")

    opts =
      Keyword.put(opts, :overrides,
        engine: [libs: [lib], env: [{"DUCKDB_LIB_DIR", Path.dirname(lib)}]]
      )

    [build] = AndroidNifs.plan(nifs, @triple, opts)
    target = Path.join(ctx.out, "target/engine")

    assert build.cd == crate

    assert build.outputs == [
             {Path.join(target, "#{@triple}/release/libengine_nif.so"), "libengine_nif.so"}
           ]

    assert build.libs == [{lib, "libduckdb.so"}]
    assert {"DUCKDB_LIB_DIR", Path.dirname(lib)} in build.env
  end

  test "an override can depend on the triple", ctx do
    {nifs, opts, _} = with_linked_lib(ctx)
    me = self()

    override = fn triple ->
      send(me, {:triple, triple})
      [libs: ["/android/#{triple}/libduckdb.so"]]
    end

    [build] = AndroidNifs.plan(nifs, @triple, Keyword.put(opts, :overrides, engine: override))
    assert_received {:triple, @triple}
    assert build.libs == [{"/android/#{@triple}/libduckdb.so", "libduckdb.so"}]

    assert AndroidNifs.plan(
             nifs,
             @triple,
             Keyword.put(opts, :overrides, engine: fn _ -> false end)
           ) == []
  end

  test "build!/3 copies libs in on every build, and fails without them", ctx do
    {nifs, opts, _} = with_linked_lib(ctx)
    lib = Path.join(ctx.tmp_dir, "android/libduckdb.so")

    [build] =
      AndroidNifs.plan(nifs, @triple, Keyword.put(opts, :overrides, engine: [libs: [lib]]))

    jni = Path.join(ctx.tmp_dir, "jni")
    File.mkdir_p!(jni)

    run = fn _dir, _cmd, _args, _env ->
      for {built, _} <- build.outputs do
        File.mkdir_p!(Path.dirname(built))
        File.write!(built, "android nif")
      end

      :ok
    end

    assert_raise Mix.Error, ~r/libduckdb\.so/, fn -> AndroidNifs.build!([build], jni, run) end

    File.mkdir_p!(Path.dirname(lib))
    File.write!(lib, "android lib v1")
    assert AndroidNifs.build!([build], jni, run) == :ok
    assert File.read!(Path.join(jni, "libduckdb.so")) == "android lib v1"
    assert File.read!(Path.join(jni, "libengine_nif.so")) == "android nif"

    # The NIF is kept; the library is copied afresh.
    File.write!(lib, "android lib v2")
    assert AndroidNifs.build!([build], jni, run) == :ok
    assert File.read!(Path.join(jni, "libduckdb.so")) == "android lib v2"
  end

  test "an app whose files are all libs builds nothing", ctx do
    {nifs, opts, _} = with_linked_lib(ctx)
    nifs = for nif <- nifs, do: %{nif | files: ["priv/native/libduckdb.so"]}

    [build] =
      AndroidNifs.plan(
        nifs,
        @triple,
        Keyword.put(opts, :overrides, engine: [libs: ["/a/libduckdb.so"]])
      )

    assert build.commands == [] and build.outputs == []
    assert build.libs == [{"/a/libduckdb.so", "libduckdb.so"}]
  end

  test "relative dep paths are expanded", ctx do
    File.cd!(ctx.tmp_dir, fn ->
      opts = Keyword.put(ctx.opts, :deps, %{"explorer" => "deps/explorer"})
      nifs = Enum.filter(AndroidNifs.find(ctx.lib), &(&1.app == "explorer"))
      [build] = AndroidNifs.plan(nifs, @triple, opts)
      assert build.cd == Path.join(ctx.deps, "explorer/native/explorer")
      {"cargo", args} = List.last(build.commands)
      assert List.last(args) == Path.join(build.cd, "Cargo.toml")
    end)
  end

  test "a dep with no known build system is an error", ctx do
    nifs = [%{app: "mystery", vsn: "1.0.0", files: ["priv/x.so"]}]
    opts = Keyword.update!(ctx.opts, :deps, &Map.put(&1, "mystery", ctx.deps))
    assert_raise ArgumentError, ~r/mystery/, fn -> AndroidNifs.plan(nifs, @triple, opts) end
  end

  test "build!/3 runs each build, keeps its outputs and copies them in", ctx do
    [_, make] = AndroidNifs.plan(AndroidNifs.find(ctx.lib), @triple, ctx.opts)
    jni = Path.join(ctx.tmp_dir, "jni")
    File.mkdir_p!(jni)
    me = self()

    run = fn dir, cmd, args, _env ->
      send(me, {:ran, dir, cmd, args})
      [{built, _}] = make.outputs
      File.mkdir_p!(Path.dirname(built))
      File.write!(built, "android elf")
      :ok
    end

    assert AndroidNifs.build!([make], jni, run) == :ok
    assert_received {:ran, _, "make", []}
    assert File.read!(Path.join(jni, "libsqlite3_nif.so")) == "android elf"

    # Kept: a second build only copies.
    File.rm!(Path.join(jni, "libsqlite3_nif.so"))
    assert AndroidNifs.build!([make], jni, run) == :ok
    refute_received {:ran, _, _, _}
    assert File.read!(Path.join(jni, "libsqlite3_nif.so")) == "android elf"
  end

  test "build!/3 patches the crate's Rustler from the cargo registry", ctx do
    [rustler, _] = AndroidNifs.plan(AndroidNifs.find(ctx.lib), @triple, ctx.opts)
    cargo_home = Path.join(ctx.tmp_dir, "cargo")
    source = Path.join(cargo_home, "registry/src/index.crates.io-x/rustler-0.36.2")
    File.mkdir_p!(Path.join(source, "src/sys"))

    File.write!(
      Path.join(source, "src/sys/nif_filler.rs"),
      "let lib = unsafe { Library::open(None::<&OsStr>, RTLD_NOW | RTLD_GLOBAL) };"
    )

    lock = Path.join(rustler.cd, "Cargo.lock")
    File.write!(lock, ~s([[package]]\nname = "rustler"\nversion = "0.36.2"\n))
    jni = Path.join(ctx.tmp_dir, "jni")
    File.mkdir_p!(jni)
    me = self()

    run = fn _dir, cmd, args, _env ->
      send(me, {:ran, cmd, args})

      for {built, _} <- rustler.outputs do
        File.mkdir_p!(Path.dirname(built))
        File.write!(built, "android elf")
      end

      :ok
    end

    previous = System.get_env("CARGO_HOME")
    System.put_env("CARGO_HOME", cargo_home)

    try do
      assert AndroidNifs.build!([rustler], jni, run) == :ok
    after
      if previous,
        do: System.put_env("CARGO_HOME", previous),
        else: System.delete_env("CARGO_HOME")
    end

    copy = Path.join([rustler.cache, "patches", "rustler-0.36.2"])
    assert File.read!(Path.join(copy, "src/sys/nif_filler.rs")) =~ "RUSTLER_BEAM_LIBRARY_PATH"
    assert_received {:ran, "cargo", ["fetch" | _]}
    assert_received {:ran, "cargo", ["build" | args]}
    assert ~s(patch.crates-io.rustler.path="#{copy}") in args
    assert File.read!(lock) =~ ~s(version = "0.36.2")
  end

  test "patch_nif_filler/1 makes Rustler before 0.38 open RUSTLER_BEAM_LIBRARY_PATH" do
    old = "let lib = unsafe { Library::open(None::<&OsStr>, RTLD_NOW | RTLD_GLOBAL) };"
    assert {:ok, patched} = AndroidNifs.patch_nif_filler(old)
    assert patched =~ ~s/std::env::var_os("RUSTLER_BEAM_LIBRARY_PATH")/
    refute patched =~ "None::<&OsStr>"

    assert AndroidNifs.patch_nif_filler(~s/const BEAM_LOC: &str = "RUSTLER_BEAM_LIBRARY_PATH";/) ==
             :unchanged
  end
end
