defmodule Mix.Tasks.Baguette.ComponentsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Baguette.Components

  test "finds the component sets among the host's Cargo features" do
    metadata = %{
      "packages" => [
        %{"name" => "baguette_abi", "features" => %{"components-nope" => []}},
        %{
          "name" => "baguette_host",
          "features" => %{
            "default" => ["components-gpui-kit"],
            "components-gpui-kit" => [],
            "components-gpui-bootstrap" => ["dep:gpui-bootstrap"],
            "playwright" => []
          }
        }
      ]
    }

    assert Components.sets(metadata) == ["gpui-bootstrap", "gpui-kit"]
  end
end
