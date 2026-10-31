defmodule Baguette.App do
  @moduledoc """
  App-wide platform calls.

  A view hears the system switch between light and dark as
  `handle_info({:appearance, :light | :dark}, assigns)`.
  """

  @doc "Opens `url` with the system's handler for it (a browser, a mail client)."
  @spec open_url(String.t()) :: :ok
  def open_url(url) when is_binary(url) do
    Baguette.Host.call("app.open_url", %{url: url})
    :ok
  end

  @doc "Whether the system draws windows light or dark."
  @spec appearance() :: :light | :dark
  def appearance do
    case Baguette.Host.call("app.appearance", %{}) do
      "dark" -> :dark
      _ -> :light
    end
  end
end
