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

  @doc """
  The platform the native host runs on: `:linux`, `:macos`, `:windows`,
  `:android` or `:ios`, or `:headless` without a host (tests, `iex -S mix`).
  Views use it to pick a layout for a phone.
  """
  @spec platform() :: :linux | :macos | :windows | :android | :ios | :headless
  def platform do
    case :init.get_argument(:baguette_platform) do
      {:ok, [[os]]} -> List.to_atom(os)
      _ -> :headless
    end
  end

  @doc "Whether the host is a phone (Android or iOS)."
  @spec mobile?() :: boolean()
  def mobile?, do: platform() in [:android, :ios]
end
