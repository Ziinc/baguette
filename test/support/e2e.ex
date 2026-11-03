defmodule Baguette.Test.E2E do
  @moduledoc false
  # `@tag skip:` values for end-to-end tests that need what a platform lacks.

  @doc "Tests that take screenshots: windows can't be captured on Windows yet (#28)."
  def screenshots do
    case :os.type() do
      {:win32, _} -> "no window capture on Windows (#28)"
      _ -> false
    end
  end

  @doc "Tests of the XDG desktop portal, which only Linux has."
  def xdg_portal do
    case :os.type() do
      {:unix, :linux} -> false
      _ -> "the XDG desktop portal is Linux's"
    end
  end
end
