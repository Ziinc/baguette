defmodule Baguette do
  @moduledoc """
  Native GPUI applications written in Elixir.

  Elixir owns application state, views, styling and tests. A Rust host
  (`native/baguette_host`, built on `tauri-plugin-gpui`) owns the main thread,
  embeds the BEAM and renders with GPUI on desktop, Android and iOS.
  """

  @doc "The Baguette version."
  @spec version() :: String.t()
  def version, do: unquote(Mix.Project.config()[:version])
end
