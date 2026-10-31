defmodule Baguette.Menu do
  @moduledoc """
  The app's menu bar.

      Baguette.Menu.set([
        {"File", [{"New job", "new_job", keys: "secondary-n"}, :separator, {"Quit", "quit"}]}
      ])

  Choosing an item sends its id to window 0's view as an event,
  `handle_event("new_job", %{}, assigns)`. `keys:` shows a shortcut next
  to it.
  """

  @type item :: {String.t(), String.t()} | {String.t(), String.t(), keyword()} | :separator

  @spec set([{String.t(), [item()]}]) :: :ok
  def set(menus) do
    menus =
      for {title, items} <- menus, do: %{"title" => title, "items" => Enum.map(items, &item/1)}

    Baguette.Host.call("menu.set", %{menus: menus})
    :ok
  end

  defp item(:separator), do: %{"separator" => true}
  defp item({label, id}), do: item({label, id, []})

  defp item({label, id, opts}) when is_binary(label) and is_binary(id) do
    item = %{"id" => id, "label" => label}
    if keys = opts[:keys], do: Map.put(item, "keys", keys), else: item
  end

  defp item(other), do: raise(ArgumentError, "not a menu item: #{inspect(other)}")
end
