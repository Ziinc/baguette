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

  @keep_all %{excluded: [], icons: :all}

  test "cargo_features/2 turns the components option into set features" do
    assert Release.cargo_features(%{}, @keep_all) == []

    assert Release.cargo_features(%{baguette: [components: ["gpui-kit"]]}, @keep_all) ==
             ~w(--no-default-features --features components-gpui-kit
                --features api-open-url --features api-pick)

    assert Release.cargo_features(%{baguette: [components: [], host_features: ["x"]]}, @keep_all) ==
             ~w(--no-default-features --features api-open-url --features api-pick --features x)
  end

  test "cargo_features/2 leaves out the APIs the plan excludes" do
    plan = %{excluded: [:pick], icons: :all}

    assert Release.cargo_features(%{}, plan) ==
             ~w(--no-default-features --features components-gpui-kit --features api-open-url)
  end

  test "icons_file/2 lists the icons to keep for the host's build, or none to keep all" do
    dir = Path.join(System.tmp_dir!(), "baguette-icons-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert Release.icons_file(%{excluded: [], icons: :all}, dir) == nil
    path = Release.icons_file(%{excluded: [], icons: {:only, MapSet.new(~w(trash plus))}}, dir)
    assert File.read!(path) == "plus\ntrash\n"
  end
end
