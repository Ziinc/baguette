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
end
