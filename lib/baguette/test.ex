defmodule Baguette.Test do
  @moduledoc """
  Helpers for testing views headlessly, the way a user would drive them.

      test "adds a todo" do
        start_supervised!({MyApp.TodoView, window: 7})
        Baguette.Test.fill(7, "Title", "Buy milk")
        Baguette.Test.submit(7, "Title")
        assert Baguette.Test.text(7) =~ "Buy milk"
      end

  Elements are found as a screen reader would: by `aria-label`, by their
  text, and for inputs also by `placeholder` or `name`. Each action sends the
  same event the native host sends, so a test fails when the control is
  missing or does not handle that action.

  | Action | Event |
  | --- | --- |
  | `click/2` | the element's `phx-click` with its `phx-value-*`; a checkbox adds `"checked"` (its new state); a `type="submit"` button submits its form |
  | `drag/4` | the element's `phx-drag` with `"dx"` and `"dy"` |
  | `fill/3` | the input's `phx-change`, or its form's, with the form's values and `"_target"` |
  | `submit/2` | the form's `phx-submit` with every named value in it |
  | `pick_file/3` | the picker's `phx-pick-file` or `phx-pick-save` with its `phx-value-*` and `"path"` |
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
    do: for({_path, el, _form} <- entries(window), labelled?(el, label), do: el)

  @doc "Clicks the element labelled `label` in `window`."
  @spec click(Host.window(), String.t()) :: :ok
  def click(window, label) do
    matches = for {_, el, _} = entry <- entries(window), labelled?(el, label), do: entry

    case {for({_, %{"a" => %{"phx-click" => _}}, _} = e <- matches, do: e), matches} do
      {[{_path, el, _form}], _} ->
        dispatch(window, "click", el["a"]["phx-click"], click_values(el))

      {[], _} ->
        case for {_, %{"t" => "button", "a" => %{"type" => "submit"}}, form} <- matches,
                 form != nil,
                 do: form do
          [form] ->
            submit_form(window, form)

          _ ->
            raise ArgumentError,
                  "no clickable element labelled #{inspect(label)} in window #{window}"
        end

      _ ->
        raise ArgumentError, "more than one clickable element labelled #{inspect(label)}"
    end
  end

  @doc """
  Drags the element labelled `label` in `window` by `dx`, `dy` pixels, as a
  pointer pressed on it, moved and released does.
  """
  @spec drag(Host.window(), String.t(), number(), number()) :: :ok
  def drag(window, label, dx, dy) do
    case for(
           {_, %{"a" => %{"phx-drag" => _}} = el, _} <- entries(window),
           labelled?(el, label),
           do: el
         ) do
      [el] ->
        dispatch(window, "drag", el["a"]["phx-drag"], values(el), %{"dx" => dx, "dy" => dy})

      [] ->
        raise ArgumentError, "no draggable element labelled #{inspect(label)} in window #{window}"

      _ ->
        raise ArgumentError, "more than one draggable element labelled #{inspect(label)}"
    end
  end

  @doc """
  Chooses `path` in the file picker labelled `label` (a `phx-pick-file` or
  `phx-pick-save` element), as picking a file in the native dialog does.
  """
  @spec pick_file(Host.window(), String.t(), String.t()) :: :ok
  def pick_file(window, label, path) do
    pickers =
      for {_, %{"a" => attrs} = el, _} <- entries(window),
          labelled?(el, label),
          event = attrs["phx-pick-file"] || attrs["phx-pick-save"],
          do: {event, el}

    case pickers do
      [{event, el}] -> dispatch(window, "pick", event, Map.put(values(el), "path", path))
      [] -> raise ArgumentError, "no file picker labelled #{inspect(label)} in window #{window}"
      _ -> raise ArgumentError, "more than one file picker labelled #{inspect(label)}"
    end
  end

  @doc """
  Types `text` into the input labelled `label` (its `aria-label`,
  `placeholder` or `name`), replacing what was there.
  """
  @spec fill(Host.window(), String.t(), String.t()) :: :ok
  def fill(window, label, text) do
    {path, el, form} = input!(window, label)
    Host.type(window, path, text, el["a"]["value"] || "")
    name = el["a"]["name"] || "value"

    # The input's own phx-change wins over its form's, as in Phoenix.
    event = el["a"]["phx-change"] || (form && elem(form, 1)["a"]["phx-change"])

    values =
      if form,
        do: form_values(window, form),
        else: %{name => text}

    if event,
      do: dispatch(window, "change", event, Map.put(values, "_target", name)),
      else: sync(window)
  end

  @doc """
  Submits the form labelled `label`, or the form around the input or button
  labelled `label`, as pressing Enter in it does.
  """
  @spec submit(Host.window(), String.t()) :: :ok
  def submit(window, label) do
    forms =
      for {path, el, form} <- entries(window),
          labelled?(el, label) or input_labelled?(el, label) do
        if el["t"] == "form", do: {path, el}, else: form
      end

    case Enum.uniq(forms) |> Enum.reject(&is_nil/1) do
      [form] -> submit_form(window, form)
      [] -> raise ArgumentError, "no form around #{inspect(label)} in window #{window}"
      _ -> raise ArgumentError, "more than one form around #{inspect(label)}"
    end
  end

  @doc "The text in the input labelled `label`: what was typed, or its `value`."
  @spec value(Host.window(), String.t()) :: String.t()
  def value(window, label) do
    {path, el, _form} = input!(window, label)
    current_value(Host.typed(window), path, el)
  end

  defp submit_form(window, {_path, form} = entry) do
    case form["a"]["phx-submit"] do
      nil -> raise ArgumentError, "the form has no phx-submit"
      event -> dispatch(window, "submit", event, form_values(window, entry))
    end
  end

  defp dispatch(window, type, event, values, extra \\ %{}) do
    Host.dispatch(
      Map.merge(
        %{"type" => type, "window" => window, "event" => event, "values" => values},
        extra
      )
    )

    sync(window)
  end

  defp click_values(%{"t" => "input", "a" => %{"type" => "checkbox"} = attrs} = el),
    do: Map.put(values(el), "checked", not Map.has_key?(attrs, "checked"))

  defp click_values(el), do: values(el)

  defp values(%{"a" => attrs}),
    do: for({"phx-value-" <> key, value} <- attrs, into: %{}, do: {key, value})

  # The named values a form submits: each text input's current text, and
  # "on" for each checked checkbox, as a browser does.
  defp form_values(window, {form_path, _form}) do
    typed = Host.typed(window)

    for {path, %{"t" => "input", "a" => %{"name" => name} = attrs} = el, {^form_path, _}} <-
          entries(window),
        value = form_value(typed, path, el, attrs),
        into: %{},
        do: {name, value}
  end

  defp form_value(_typed, _path, _el, %{"type" => "checkbox"} = attrs),
    do: if(Map.has_key?(attrs, "checked"), do: "on")

  defp form_value(typed, path, el, _attrs), do: current_value(typed, path, el)

  defp current_value(typed, path, el) do
    rendered = el["a"]["value"] || ""

    case typed do
      %{^path => {text, ^rendered}} -> text
      _ -> rendered
    end
  end

  defp input!(window, label) do
    case for {_, el, _} = entry <- entries(window),
             text_input?(el),
             input_labelled?(el, label),
             do: entry do
      [entry] -> entry
      [] -> raise ArgumentError, "no input labelled #{inspect(label)} in window #{window}"
      _ -> raise ArgumentError, "more than one input labelled #{inspect(label)}"
    end
  end

  defp text_input?(%{"t" => "input", "a" => attrs}),
    do: attrs["type"] not in ["checkbox", "submit"]

  defp text_input?(%{"t" => "textarea"}), do: true
  defp text_input?(_), do: false

  defp input_labelled?(%{"t" => tag, "a" => attrs} = el, label) when tag in ["input", "textarea"],
    do: labelled?(el, label) or attrs["placeholder"] == label or attrs["name"] == label

  defp input_labelled?(_el, _label), do: false

  # Waits until the owner of `window` has handled everything sent to it, and
  # the host has stored what it rendered in response.
  defp sync(window) do
    case Host.owner(window) do
      nil -> :ok
      pid -> :sys.get_state(pid)
    end

    :ok
  end

  # Every element with its path (as the native host numbers them: "root",
  # then ".<index>" among all children, text included) and its enclosing
  # form as `{path, element}`, or nil.
  defp entries(window), do: walk(tree(window), "root", nil)

  defp walk(%{"c" => children} = el, path, form) do
    inner = if el["t"] == "form", do: {path, el}, else: form

    children_entries =
      children
      |> Enum.with_index()
      |> Enum.flat_map(fn {child, i} -> walk(child, "#{path}.#{i}", inner) end)

    [{path, el, form} | children_entries]
  end

  defp walk(_text, _path, _form), do: []

  defp texts(nil), do: []
  defp texts(text) when is_binary(text), do: [text]
  defp texts(%{"c" => children}), do: Enum.flat_map(children, &texts/1)

  defp labelled?(%{"a" => %{"aria-label" => label}}, label), do: true
  defp labelled?(el, label), do: el |> texts() |> Enum.join(" ") == label
end
