defmodule Baguette.Test do
  @moduledoc """
  Helpers for testing views headlessly, the way a user would drive them.

      test "increments" do
        start_supervised!({MyApp.CounterView, window: 7})
        assert Baguette.Test.text(7) =~ "Count: 0"
        Baguette.Test.click(7, "Increment")
        assert Baguette.Test.text(7) =~ "Count: 1"
      end

  `click/2` finds the element by its `aria-label` or its text, as a screen
  reader would, and sends the same event the native host sends when it is
  clicked, so a test fails when the control is missing or not clickable.
  """

  alias Baguette.Host

  @doc "The root node last rendered to `window`."
  @spec tree(Host.window()) :: Baguette.Tree.tree() | nil
  def tree(window) do
    sync(window)
    with %{"root" => root} <- Host.last_frame(window), do: root
  end

  @doc "All text rendered to `window`, joined by spaces."
  @spec text(Host.window()) :: String.t()
  def text(window), do: window |> tree() |> texts() |> Enum.join(" ")

  @doc "Every element in `window` whose `aria-label` or text is `label`."
  @spec find_all(Host.window(), String.t()) :: [map()]
  def find_all(window, label),
    do: window |> tree() |> elements() |> Enum.filter(&labelled?(&1, label))

  @doc "Clicks the element labelled `label` in `window`."
  @spec click(Host.window(), String.t()) :: :ok
  def click(window, label) do
    {event, values} = target!(window, label, "phx-click", "clickable")
    Host.dispatch(%{"type" => "click", "window" => window, "event" => event, "values" => values})
    sync(window)
  end

  @doc """
  Drags the element labelled `label` in `window` by `dx`, `dy` pixels, as a
  pointer pressed on it, moved and released does.
  """
  @spec drag(Host.window(), String.t(), number(), number()) :: :ok
  def drag(window, label, dx, dy) do
    {event, values} = target!(window, label, "phx-drag", "draggable")

    Host.dispatch(%{
      "type" => "drag",
      "window" => window,
      "event" => event,
      "values" => values,
      "dx" => dx,
      "dy" => dy
    })

    sync(window)
  end

  defp target!(window, label, binding, kind) do
    case for(%{"a" => %{^binding => _}} = el <- find_all(window, label), do: el) do
      [%{"a" => attrs}] ->
        values = for {"phx-value-" <> key, value} <- attrs, into: %{}, do: {key, value}
        {attrs[binding], values}

      [] ->
        raise ArgumentError, "no #{kind} element labelled #{inspect(label)} in window #{window}"

      _ ->
        raise ArgumentError, "more than one #{kind} element labelled #{inspect(label)}"
    end
  end

  # Waits until the owner of `window` has handled everything sent to it, and
  # the host has stored what it rendered in response.
  defp sync(window) do
    case Host.owner(window) do
      nil -> :ok
      pid -> :sys.get_state(pid)
    end

    :ok
  end

  defp elements(nil), do: []
  defp elements(text) when is_binary(text), do: []
  defp elements(%{"c" => children} = el), do: [el | Enum.flat_map(children, &elements/1)]

  defp texts(nil), do: []
  defp texts(text) when is_binary(text), do: [text]
  defp texts(%{"c" => children}), do: Enum.flat_map(children, &texts/1)

  defp labelled?(%{"a" => %{"aria-label" => label}}, label), do: true
  defp labelled?(el, label), do: el |> texts() |> Enum.join(" ") == label
end
