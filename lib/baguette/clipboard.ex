defmodule Baguette.Clipboard do
  @moduledoc "The system clipboard's text, through GPUI."

  @doc "The text on the clipboard, or `nil`."
  @spec read() :: String.t() | nil
  def read, do: Baguette.Host.call("clipboard.read", %{})

  @doc "Puts `text` on the clipboard."
  @spec write(String.t()) :: :ok
  def write(text) when is_binary(text),
    do: ok(Baguette.Host.call("clipboard.write", %{text: text}))

  defp ok(_), do: :ok
end
