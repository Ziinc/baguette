defmodule Baguette.Tree do
  @moduledoc """
  Turns rendered HEEx into the node tree the native host draws.

  A node is either a string or `%{"t" => tag, "a" => attrs, "c" => children}`.
  Whitespace-only text between elements is dropped, as a browser would
  collapse it.
  """

  @type tree :: String.t() | %{String.t() => term()}

  @spec from_rendered(Phoenix.LiveView.Rendered.t() | iodata()) :: tree() | nil
  def from_rendered(%Phoenix.LiveView.Rendered{} = rendered) do
    rendered |> Phoenix.HTML.Safe.to_iodata() |> from_html()
  end

  def from_rendered(html), do: from_html(html)

  @spec from_html(iodata()) :: tree() | nil
  def from_html(html) do
    html
    |> IO.iodata_to_binary()
    |> Floki.parse_fragment!()
    |> Enum.flat_map(&to_node/1)
    |> case do
      [] -> nil
      [root] -> root
      children -> %{"t" => "div", "a" => %{}, "c" => children}
    end
  end

  defp to_node({tag, attrs, children}) do
    [%{"t" => tag, "a" => Map.new(attrs), "c" => Enum.flat_map(children, &to_node/1)}]
  end

  defp to_node(text) when is_binary(text) do
    case String.trim(text) do
      "" -> []
      _ -> [collapse(text)]
    end
  end

  defp to_node(_comment), do: []

  defp collapse(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
