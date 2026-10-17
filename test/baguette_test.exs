defmodule BaguetteTest do
  use ExUnit.Case, async: true

  test "version/0 matches the Mix project" do
    assert Baguette.version() == Mix.Project.config()[:version]
  end
end
