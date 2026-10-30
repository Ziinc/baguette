defmodule Baguette.Test.Kit do
  @moduledoc false
  # Components from a fixture manifest, for Baguette.ComponentsTest.
  use Baguette.Components, manifest: "../fixtures/components.json", prefix: "kit-"
end
