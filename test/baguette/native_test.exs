defmodule Baguette.NativeTest do
  use ExUnit.Case, async: true
  alias Baguette.Native.Precompiled

  test "the NIF downloads precompiled unless asked to build or unreleased" do
    refute Precompiled.force_build?(%{}, true)
    assert Precompiled.force_build?(%{"BAGUETTE_BUILD_NIF" => "1"}, true)
    assert Precompiled.force_build?(%{"BAGUETTE_BUILD_NIF" => "true"}, true)
    # No checksums: this is a checkout, not a published package.
    assert Precompiled.force_build?(%{}, false)
  end

  test "every target is built by the release workflow" do
    workflow = File.read!(".github/workflows/nif.yml")

    for target <- Precompiled.targets() do
      assert workflow =~ "target: #{target}", "#{target} is missing from nif.yml"
    end
  end

  test "downloads come from this version's GitHub release" do
    assert Precompiled.base_url() ==
             "https://github.com/ziinc/baguette/releases/download/v#{Baguette.version()}"
  end

  test "the hex package ships the checksums and sources, not build output" do
    files = Mix.Project.config()[:package][:files]
    assert "checksum-Elixir.Baguette.Native.exs" in files
    assert "native/baguette_nif" in files
    refute Enum.any?(files, &String.contains?(&1, "target"))
    refute "priv" in files
  end
end
