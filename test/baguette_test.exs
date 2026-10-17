defmodule BaguetteTest do
  use ExUnit.Case, async: true

  test "version/0 matches the Mix project" do
    assert Baguette.version() == Mix.Project.config()[:version]
  end

  test "platform/0 is :headless without a native host" do
    assert Baguette.platform() == :headless
    refute Baguette.mobile?()
  end
end
