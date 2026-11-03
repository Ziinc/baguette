defmodule Baguette.Release.IosNifsTest do
  use ExUnit.Case, async: true
  alias Baguette.Release.{AndroidNifs, IosNifs}

  @triple "aarch64-apple-ios-sim"

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    lib = Path.join(tmp, "rel/lib")
    deps = Path.join(tmp, "deps")

    write = fn path, content ->
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    # A precompiled Rustler NIF, an elixir_make NIF and Baguette's own.
    write.(
      Path.join(
        lib,
        "mdex-0.9.0/priv/native/libcomrak_nif-v0.9.0-nif-2.15-aarch64-apple-darwin.so"
      ),
      "macho"
    )

    write.(Path.join(lib, "exqlite-0.43.0/priv/sqlite3_nif.so"), "macho")
    write.(Path.join(lib, "baguette-0.1.0/priv/native/baguette_nif.so"), "macho")

    write.(Path.join(deps, "mdex/native/comrak_nif/Cargo.toml"), """
    [package]
    name = "comrak-nif"
    version = "0.1.0"

    [lib]
    name = "comrak_nif"
    crate-type = ["cdylib"]
    """)

    write.(
      Path.join(deps, "mdex/native/comrak_nif/Cargo.lock"),
      ~s([[package]]\nname = "rustler"\nversion = "0.38.0"\n)
    )

    write.(Path.join(deps, "exqlite/Makefile"), "all:\n")

    opts = [
      deps: %{"mdex" => Path.join(deps, "mdex"), "exqlite" => Path.join(deps, "exqlite")},
      sdk: "iphonesimulator",
      cc: "/baguette/priv/ios/nif-cc",
      erts_include: "/erts/include",
      out: Path.join(tmp, "nifs"),
      skip: [:baguette]
    ]

    %{lib: lib, deps: deps, opts: opts, out: Path.join(tmp, "nifs")}
  end

  test "a Rustler NIF is built as a static library named after its crate", ctx do
    [_make, rustler] = IosNifs.plan(AndroidNifs.find(ctx.lib), @triple, ctx.opts)
    crate = Path.join(ctx.deps, "mdex/native/comrak_nif")
    target = Path.join([ctx.out, "target", "mdex"])

    assert %{app: "mdex", kind: :rustler, cd: ^crate} = rustler

    assert {"cargo",
            [
              "rustc",
              "--release",
              "--lib",
              "--target",
              @triple,
              "--target-dir",
              ^target,
              "--manifest-path",
              _,
              "--crate-type",
              "staticlib"
            ]} = List.last(rustler.commands)

    assert rustler.outputs == [
             {Path.join([target, @triple, "release", "libcomrak_nif.a"]), "comrak_nif"}
           ]
  end

  test "an elixir_make NIF is built by its Makefile with the wrapper compiler", ctx do
    [make, _rustler] = IosNifs.plan(AndroidNifs.find(ctx.lib), @triple, ctx.opts)
    scratch = Path.join(ctx.out, "#{@triple}/exqlite-0.43.0/build")

    assert %{app: "exqlite", kind: :make, cd: cd} = make
    assert cd == Path.join(ctx.deps, "exqlite")
    assert [{"make", []}, {"xcrun", ["ar", "rcs", archive, object]}] = make.commands
    assert archive == Path.join(scratch, "libsqlite3_nif.a")
    assert object == Path.join(scratch, "priv/sqlite3_nif.so")

    env = Map.new(make.env)
    assert env["CC"] == "/baguette/priv/ios/nif-cc"
    assert env["CXX"] == "/baguette/priv/ios/nif-cc++"
    assert env["BAGUETTE_NIF_CC_NAME"] == "sqlite3_nif"
    assert env["BAGUETTE_NIF_CC_SDK"] == "iphonesimulator"
    assert env["MIX_APP_PATH"] == scratch
    assert make.outputs == [{archive, "sqlite3_nif"}]
  end

  test "ios_nifs skips or tunes a dependency", ctx do
    opts = Keyword.put(ctx.opts, :overrides, exqlite: false, mdex: [args: ["--features", "x"]])
    [rustler] = IosNifs.plan(AndroidNifs.find(ctx.lib), @triple, opts)
    assert {"cargo", args} = List.last(rustler.commands)
    assert Enum.take(args, -2) == ["--features", "x"]
  end

  test "Rustler before 0.37 is refused: its init functions all share a name", ctx do
    File.write!(
      Path.join(ctx.deps, "mdex/native/comrak_nif/Cargo.lock"),
      ~s([[package]]\nname = "rustler"\nversion = "0.36.1"\n)
    )

    assert_raise ArgumentError, ~r/Rustler 0.36.1; iOS needs 0.37/, fn ->
      IosNifs.plan(AndroidNifs.find(ctx.lib), @triple, ctx.opts)
    end
  end

  test "builds run once, then their archives are kept", ctx do
    [make, _] = IosNifs.plan(AndroidNifs.find(ctx.lib), @triple, ctx.opts)
    link = Path.join(ctx.tmp_dir, "link")
    parent = self()

    run = fn _dir, cmd, args, _env ->
      send(parent, {:ran, cmd})

      if cmd == "xcrun" do
        [_, _, archive, _] = args
        File.mkdir_p!(Path.dirname(archive))
        File.write!(archive, "!<arch>\n")
      end

      :ok
    end

    assert IosNifs.build!([make], link, run) == ["sqlite3_nif"]
    assert_received {:ran, "make"}
    assert File.regular?(Path.join(link, "libsqlite3_nif.a"))

    assert IosNifs.build!([make], link, run) == ["sqlite3_nif"]
    refute_received {:ran, "make"}
  end
end
