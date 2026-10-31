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

    Release.trim_erts!(root)

    assert Enum.sort(File.ls!(Path.join(erts, "bin"))) == ["erl_child_setup", "inet_gethost"]
    assert File.ls!(erts) == ["bin"]
  end

  @tag :tmp_dir
  test "trim_erts!/1 leaves a release without ERTS alone", %{tmp_dir: root} do
    assert Release.trim_erts!(root) == :ok
  end
end
