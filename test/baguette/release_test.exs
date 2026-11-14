defmodule Baguette.ReleaseTest do
  use ExUnit.Case, async: false
  alias Baguette.Release

  setup do
    on_exit(fn -> System.delete_env("BAGUETTE_HOST_FEATURES") end)
  end

  test "host_features/1 reads the release option" do
    assert Release.host_features(%{baguette: [host_features: ["a"]]}) == ["a"]
    assert Release.host_features(%{}) == []
  end

  test "host_features/1 adds BAGUETTE_HOST_FEATURES, comma separated" do
    System.put_env("BAGUETTE_HOST_FEATURES", "playwright, b,a")
    assert Release.host_features(%{baguette: [host_features: ["a"]]}) == ["a", "playwright", "b"]
  end

  test "cargo_features/1 turns the components option into set features" do
    assert Release.cargo_features(%{}) == []

    assert Release.cargo_features(%{baguette: [components: ["gpui-kit"]]}) ==
             ["--no-default-features", "--features", "components-gpui-kit"]

    assert Release.cargo_features(%{baguette: [components: [], host_features: ["x"]]}) ==
             ["--no-default-features", "--features", "x"]
  end

  describe "host_source/2" do
    test "a default host is downloaded, precompiled" do
      assert Release.host_source([], %{}) == :precompiled
      assert Release.host_source([baguette: [components: ["gpui-kit"]]], %{}) == :precompiled
    end

    test "another component set, a host feature or BAGUETTE_BUILD_HOST builds it" do
      assert Release.host_source([baguette: [components: []]], %{}) == :build
      assert Release.host_source([baguette: [host_features: ["playwright"]]], %{}) == :build
      assert Release.host_source([], %{"BAGUETTE_HOST_FEATURES" => "playwright"}) == :build
      assert Release.host_source([], %{"BAGUETTE_BUILD_HOST" => "1"}) == :build
    end

    test "BAGUETTE_HOST_BINARY uses a host built elsewhere" do
      assert Release.host_source([baguette: [host_features: ["playwright"]]], %{
               "BAGUETTE_HOST_BINARY" => "/tmp/host"
             }) == {:local, "/tmp/host"}
    end
  end

  test "host_asset/3 names the precompiled host as the host workflow publishes it" do
    assert Release.host_asset("0.2.0", "29.1.2", "x86_64-linux") ==
             "baguette_host-v0.2.0-OTP-29.1.2-x86_64-linux.tar.gz"
  end

  test "the host workflow builds every desktop target, named as host_asset/3 names them" do
    workflow = File.read!(".github/workflows/host.yml")

    for target <- ~w(x86_64-linux aarch64-linux aarch64-macos x86_64-macos) do
      assert workflow =~ "target: #{target}"
    end

    assert workflow =~ ~s(asset="baguette_host-v$version-${OTP_TAG}-${{ matrix.target }}.tar.gz")
    assert Release.host_asset("V", "X", "T") == "baguette_host-vV-OTP-X-T.tar.gz"
    assert workflow =~ "OTP_TAG: OTP-"
  end

  describe "levain_revision/1" do
    test "reads the repository and revision levain is pinned to" do
      cargo = """
      [dependencies]
      levain = { git = "https://github.com/Ziinc/levain", rev = "268f2c3cc21", default-features = false }
      """

      assert Release.levain_revision(cargo) == {"https://github.com/Ziinc/levain", "268f2c3cc21"}
    end

    test "raises without a pin" do
      for cargo <- [
            "",
            ~s(levain = { path = "../../../levain" }\n),
            ~s(levain = { git = "https://github.com/Ziinc/levain", branch = "main" }\n)
          ] do
        assert_raise Mix.Error, ~r/pins no levain revision/, fn ->
          Release.levain_revision(cargo)
        end
      end
    end

    test "the host reads the pin from its own Cargo.toml" do
      assert {"https://" <> _, rev} = Release.levain_revision()
      assert rev =~ ~r/^[0-9a-f]{40}$/
    end

    test "baguette_host, baguette_beam and baguette_nif pin the same levain revision" do
      pins =
        for crate <- ~w(baguette_host baguette_beam baguette_nif), into: %{} do
          cargo = File.read!("native/#{crate}/Cargo.toml")

          assert [_, repo, rev] =
                   Regex.run(
                     ~r/^levain(?:-abi)? = \{ git = "([^"]+)", rev = "([0-9a-f]+)"/m,
                     cargo
                   ),
                 "native/#{crate}/Cargo.toml pins no levain revision"

          {crate, {repo, rev}}
        end

      assert pins |> Map.values() |> Enum.uniq() |> length() == 1, inspect(pins)
    end
  end

  describe "levain_pack_source/3" do
    @sums %{
      "levain-pack-v0.3.0-x86_64-linux.tar.gz" => "aa",
      "levain-pack-v0.3.0-aarch64-macos.tar.gz" => "bb"
    }

    test "LEVAIN_PACK uses a levain-pack built elsewhere, even with a pinned checksum" do
      assert Release.levain_pack_source(%{"LEVAIN_PACK" => "/tmp/pack"}, @sums, "x86_64-linux") ==
               {:local, "/tmp/pack"}
    end

    test "a pinned checksum downloads this target's levain-pack from levain's release" do
      assert Release.levain_pack_source(%{}, @sums, "aarch64-macos") ==
               {:precompiled,
                "https://github.com/Ziinc/levain/releases/download/v0.3.0/levain-pack-v0.3.0-aarch64-macos.tar.gz",
                "bb"}
    end

    test "without either, levain-pack is built from the pinned levain" do
      assert Release.levain_pack_source(%{}, %{}, "x86_64-linux") == :build
      assert Release.levain_pack_source(%{}, @sums, "x86_64-windows") == :build
      # Another target's name is not a suffix match.
      assert Release.levain_pack_source(%{}, @sums, "linux") == :build
    end
  end

  test "env_args/1 passes each variable to levain-pack as --env NAME=value" do
    assert Release.env_args([]) == []

    assert Release.env_args([{"A", "1"}, {"B", "x=y"}]) ==
             ["--env", "A=1", "--env", "B=x=y"]
  end

  test "levain-pack comes from levain's releases, not the host workflow" do
    refute File.read!(".github/workflows/host.yml") =~ "levain-pack"
    assert "priv/levain-pack.sha256" in Mix.Project.config()[:package][:files]
    assert File.exists?("priv/levain-pack.sha256")
  end

  test "precompiled hosts are built for size, with the dist profile" do
    workflow = File.read!(".github/workflows/host.yml")
    assert workflow =~ "cargo build --profile dist -p baguette_host"
    assert workflow =~ "native/target/dist baguette_host"

    cargo = File.read!("native/Cargo.toml")

    assert cargo =~
             ~r/\[profile\.dist\]\ninherits = "release"\nlto = "fat"\ncodegen-units = 1\nopt-level = "s"/
  end

  @tag :tmp_dir
  test "trim_erts!/1 keeps only the programs the host's BEAM starts", %{tmp_dir: root} do
    erts = Path.join(root, "erts-17.1.1")

    for file <- ~w(bin/beam.smp bin/erlexec bin/epmd bin/erl_child_setup bin/inet_gethost
                   include/erl_nif.h lib/liberts.a doc/README man/man1/erl.1) do
      File.mkdir_p!(Path.dirname(Path.join(erts, file)))
      File.write!(Path.join(erts, file), "x")
    end

    Release.trim_erts!(root, {:unix, :linux})

    assert Enum.sort(File.ls!(Path.join(erts, "bin"))) == ["erl_child_setup", "inet_gethost"]
    assert File.ls!(erts) == ["bin"]
  end

  @tag :tmp_dir
  test "trim_erts!/2 on Windows keeps the BEAM's DLL, which the host loads", %{tmp_dir: root} do
    erts = Path.join(root, "erts-17.1.1")

    for file <- ~w(bin/beam.smp.dll bin/erlexec.dll bin/erl.exe bin/epmd.exe
                   bin/inet_gethost.exe include/erl_nif.h) do
      File.mkdir_p!(Path.dirname(Path.join(erts, file)))
      File.write!(Path.join(erts, file), "x")
    end

    Release.trim_erts!(root, {:win32, :nt})

    assert Enum.sort(File.ls!(Path.join(erts, "bin"))) == ["beam.smp.dll", "inet_gethost.exe"]
    assert File.ls!(erts) == ["bin"]
  end

  @tag :tmp_dir
  test "trim_erts!/1 leaves a release without ERTS alone", %{tmp_dir: root} do
    assert Release.trim_erts!(root) == :ok
  end

  describe "ios_build_options/2" do
    @sim %{simulator: true}
    @device %{simulator: false}

    test "the simulator gets an unsigned debug build, whatever signing is set up" do
      env = %{"APPLE_DEVELOPMENT_TEAM" => "T", "BAGUETTE_IOS_EXPORT_METHOD" => "debugging"}
      assert Release.ios_build_options(@sim, env) == ["--debug", "--no-sign"]
    end

    test "a device gets an optimised build, unsigned without a development team" do
      assert Release.ios_build_options(@device, %{}) == ["--no-sign"]
    end

    test "a development team turns signing on, with the export method chosen" do
      env = %{
        "APPLE_DEVELOPMENT_TEAM" => "T",
        "BAGUETTE_IOS_EXPORT_METHOD" => "app-store-connect"
      }

      assert Release.ios_build_options(@device, env) == ["--export-method", "app-store-connect"]
    end

    test "BAGUETTE_IOS_PROFILE chooses debug or release" do
      assert Release.ios_build_options(@sim, %{"BAGUETTE_IOS_PROFILE" => "release"}) ==
               ["--no-sign"]

      assert Release.ios_build_options(@device, %{"BAGUETTE_IOS_PROFILE" => "debug"}) ==
               ["--debug", "--no-sign"]
    end
  end
end
