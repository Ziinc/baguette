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
    assert AndroidNifs.jni_name("priv/native/libfoo.so") == "liblibfoo.so"

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
             {Path.join(target, "#{@triple}/release/libexplorer.so"),
              "liblibexplorer-v0.13.0-nif-2.15-x86_64-unknown-linux-gnu.so"}
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

  test "patch_nif_filler/1 makes Rustler before 0.38 open RUSTLER_BEAM_LIBRARY_PATH" do
    old = "let lib = unsafe { Library::open(None::<&OsStr>, RTLD_NOW | RTLD_GLOBAL) };"
    assert {:ok, patched} = AndroidNifs.patch_nif_filler(old)
    assert patched =~ ~s/std::env::var_os("RUSTLER_BEAM_LIBRARY_PATH")/
    refute patched =~ "None::<&OsStr>"

    assert AndroidNifs.patch_nif_filler(~s/const BEAM_LOC: &str = "RUSTLER_BEAM_LIBRARY_PATH";/) ==
             :unchanged
  end
end
