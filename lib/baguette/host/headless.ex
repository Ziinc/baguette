defmodule Baguette.Host.Headless do
  @moduledoc false
  # The platform without a native host: platform calls change this state,
  # which tests read back with `Baguette.Host.platform/0`.

  def new do
    %{
      clipboard: nil,
      windows: %{0 => %{"title" => nil, "x" => nil, "y" => nil, "width" => 800, "height" => 600}},
      opened_urls: [],
      menus: [],
      appearance: "light"
    }
  end

  def call("clipboard.read", _args, p), do: {p.clipboard, p}
  def call("clipboard.write", %{text: text}, p), do: {nil, %{p | clipboard: text}}
  def call("app.open_url", %{url: url}, p), do: {nil, %{p | opened_urls: p.opened_urls ++ [url]}}
  def call("app.appearance", _args, p), do: {p.appearance, p}
  def call("menu.set", %{menus: menus}, p), do: {nil, %{p | menus: menus}}
  def call("window.info", %{window: w}, p), do: {p.windows[w], p}

  def call("window.open", %{window: w} = args, p) do
    window = %{"title" => args[:title], "x" => nil, "y" => nil}

    window =
      Map.merge(window, %{"width" => args[:width] || 800, "height" => args[:height] || 600})

    {nil, put_in(p.windows[w], window)}
  end

  def call("window.close", %{window: w}, p), do: {nil, %{p | windows: Map.delete(p.windows, w)}}

  def call("window.set_title", %{window: w, title: title}, p),
    do: {nil, update_window(p, w, %{"title" => title})}

  def call("window.set_bounds", %{window: w} = args, p) do
    bounds = for {k, v} <- Map.delete(args, :window), into: %{}, do: {Atom.to_string(k), v}
    {nil, update_window(p, w, bounds)}
  end

  defp update_window(p, w, changes) do
    case p.windows do
      %{^w => window} -> put_in(p.windows[w], Map.merge(window, changes))
      _ -> p
    end
  end
end
