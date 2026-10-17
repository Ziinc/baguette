defmodule Baguette.ThemeTest do
  use ExUnit.Case, async: true

  defmodule Theme do
    use Baguette.Theme
    token(:primary, light: "#2563eb", dark: "#3b82f6")
    token(:primary_foreground, "#ffffff")
  end

  test "tokens per appearance, with dashed names" do
    assert Theme.tokens() == %{"primary" => "#2563eb", "primary-foreground" => "#ffffff"}
    assert Theme.tokens(:dark)["primary"] == "#3b82f6"
  end
end
