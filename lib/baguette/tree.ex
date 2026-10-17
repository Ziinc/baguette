defmodule Baguette.Tree do
  @moduledoc """
  Turns rendered HEEx into the node tree the native host draws.

  A node is either a string or `%{"t" => tag, "a" => attrs, "c" => children}`.
  Whitespace-only text between elements is dropped, as a browser would
  collapse it.

  A template's static HTML is parsed once and cached by its fingerprint; each
  render then only fills in the dynamic values. Anything the cache can't
  express (raw HTML in a dynamic, a live component) falls back to parsing the
  whole render, so both paths always produce the same tree.
  """

  alias Phoenix.LiveView.{Comprehension, Rendered}

  @type tree :: String.t() | %{String.t() => term()}

  # Stand-ins for dynamic slots while parsing a template's statics: private-use
  # characters, so the parser keeps them in text, attribute values and
  # attribute names alike.
  @open "\u{E000}"
  @close "\u{E001}"
  @slot ~r/\x{E000}(\d+)\x{E001}/u

  @spec from_rendered(Phoenix.LiveView.Rendered.t() | iodata()) :: tree() | nil
  def from_rendered(%Rendered{} = rendered) do
    rendered |> fill() |> root()
  catch
    :fallback -> rendered |> Phoenix.HTML.Safe.to_iodata() |> from_html()
  end

  def from_rendered(html), do: from_html(html)

  @spec from_html(iodata()) :: tree() | nil
  def from_html(html) do
    html
    |> IO.iodata_to_binary()
    |> Floki.parse_fragment!()
    |> Enum.flat_map(&to_node/1)
    |> root()
  end

  defp root([]), do: nil
  defp root([root]), do: root
  defp root(children), do: %{"t" => "div", "a" => %{}, "c" => children}

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

  @whitespace [" ", "\t", "\n", "\v", "\f", "\r"]

  defp collapse(text),
    do: text |> :binary.split(@whitespace, [:global, :trim_all]) |> Enum.join(" ")

  ## Cached templates

  # A template is a list of pieces: raw text, finished text `{:text, text}`,
  # `{:slot, i}`, or
  # `{:el, tag, static_attrs, dynamic_attrs, attr_slots, children}`, where
  # `dynamic_attrs` values are lists of text and `{:slot, i}` parts, and
  # `attr_slots` are slots that render whole attributes.

  # Pieces are collected in reverse, then `normalize/1` restores the order
  # while joining adjacent text.
  defp fill(rendered), do: fill(rendered, []) |> normalize()

  defp fill(%Rendered{static: static, fingerprint: fingerprint, dynamic: dynamic}, acc),
    do: fill(template(fingerprint, static), List.to_tuple(dynamic.(false)), acc)

  defp fill(%Comprehension{static: static, fingerprint: fingerprint, entries: entries}, acc) do
    template = template(fingerprint, static)

    Enum.reduce(entries, acc, fn {_key, _vars, render}, acc ->
      fill(template, List.to_tuple(render.(%{}, false)), acc)
    end)
  end

  defp fill(%_{}, _acc), do: throw(:fallback)

  defp fill([], _dynamics, acc), do: acc

  defp fill([piece | rest], dynamics, acc),
    do: fill(rest, dynamics, fill_piece(piece, dynamics, acc))

  defp fill_piece(text, _dynamics, acc) when is_binary(text), do: [text | acc]
  defp fill_piece({:text, _} = text, _dynamics, acc), do: [text | acc]

  defp fill_piece({:slot, i}, dynamics, acc) do
    case elem(dynamics, i) do
      nil -> acc
      %_{} = nested -> fill(nested, acc)
      iodata -> [text(iodata) | acc]
    end
  end

  defp fill_piece({:el, tag, attrs, dynamic_attrs, attr_slots, children}, dynamics, acc) do
    attrs =
      Enum.reduce(dynamic_attrs, attrs, fn {name, parts}, attrs ->
        Map.put(attrs, name, fill_value(parts, dynamics))
      end)

    attrs =
      Enum.reduce(attr_slots, attrs, fn i, attrs ->
        parse_attributes(text(elem(dynamics, i)), attrs)
      end)

    children = children |> fill(dynamics, []) |> normalize()
    [%{"t" => tag, "a" => attrs, "c" => children} | acc]
  end

  defp fill_value(parts, dynamics) do
    Enum.map_join(parts, fn
      {:slot, i} -> text(elem(dynamics, i))
      text -> text
    end)
  end

  # Dynamic text arrives HTML-escaped; anything else (raw HTML, other
  # entities) needs the full parser.
  defp text(nil), do: ""
  defp text(%_{}), do: throw(:fallback)

  defp text(iodata) do
    text = if is_binary(iodata), do: iodata, else: IO.iodata_to_binary(iodata)
    if :binary.match(text, "<") != :nomatch, do: throw(:fallback)

    case :binary.split(text, "&", [:global]) do
      [text] -> text
      [head | rest] -> IO.iodata_to_binary([head | Enum.map(rest, &unescape/1)])
    end
  end

  defp unescape("amp;" <> rest), do: ["&", rest]
  defp unescape("lt;" <> rest), do: ["<", rest]
  defp unescape("gt;" <> rest), do: [">", rest]
  defp unescape("quot;" <> rest), do: ["\"", rest]
  defp unescape("#39;" <> rest), do: ["'", rest]
  defp unescape(_), do: throw(:fallback)

  # The attributes `Phoenix.HTML.attributes_escape/1` writes: ` name="value"`
  # or a bare ` name`, values escaped.
  defp parse_attributes("", attrs), do: attrs
  defp parse_attributes(" " <> rest, attrs), do: parse_attributes(rest, attrs)

  defp parse_attributes(text, attrs) do
    case :binary.match(text, [" ", "=\""]) do
      {at, 2} ->
        <<name::binary-size(^at), "=\"", rest::binary>> = text

        case :binary.split(rest, "\"") do
          [value, rest] ->
            parse_attributes(rest, Map.put(attrs, String.downcase(name), text(value)))

          _ ->
            throw(:fallback)
        end

      {at, 1} ->
        <<name::binary-size(^at), rest::binary>> = text
        parse_attributes(rest, Map.put(attrs, String.downcase(name), String.downcase(name)))

      :nomatch ->
        Map.put(attrs, String.downcase(text), String.downcase(text))
    end
  end

  # Restores the order of reversed pieces, joining adjacent text and dropping
  # what the browser would collapse, exactly as `to_node/1` treats parsed text.
  defp normalize(reversed), do: normalize(reversed, [], [])

  defp normalize([text | rest], texts, nodes) when is_binary(text),
    do: normalize(rest, [text | texts], nodes)

  defp normalize([{:text, text} | rest], texts, nodes),
    do: normalize(rest, [], [text | flush(texts, nodes)])

  defp normalize([node | rest], texts, nodes),
    do: normalize(rest, [], [node | flush(texts, nodes)])

  defp normalize([], texts, nodes), do: flush(texts, nodes)

  defp flush([], nodes), do: nodes
  defp flush([text], nodes), do: to_node(text) ++ nodes
  defp flush(texts, nodes), do: to_node(IO.iodata_to_binary(texts)) ++ nodes

  defp template(_fingerprint, static) when not is_list(static), do: throw(:fallback)

  defp template(fingerprint, static) do
    key = {__MODULE__, fingerprint}

    case :persistent_term.get(key, nil) do
      nil ->
        template = compile(static)
        :persistent_term.put(key, template)
        template

      template ->
        template
    end
    |> case do
      :fallback -> throw(:fallback)
      template -> template
    end
  end

  defp compile(static) do
    slots = length(static) - 1

    html =
      static
      |> Enum.with_index()
      |> Enum.map_join(fn
        {part, ^slots} -> part
        {part, i} -> part <> @open <> Integer.to_string(i) <> @close
      end)

    template = html |> Floki.parse_fragment!() |> Enum.flat_map(&compile_node/1)
    if slots_in(template) == Enum.to_list(0..(slots - 1)//1), do: template, else: :fallback
  end

  defp compile_node({tag, attrs, children}) do
    {attr_slots, attrs} =
      Enum.split_with(attrs, fn {name, _} -> String.starts_with?(name, @open) end)

    attr_slots = for {name, _} <- attr_slots, [_, i] <- Regex.scan(@slot, name), do: slot(i)

    {static_attrs, dynamic_attrs} =
      attrs
      |> Enum.map(fn {name, value} -> {name, split(value)} end)
      |> Enum.split_with(&match?({_, [text]} when is_binary(text), &1))

    static_attrs = Map.new(static_attrs, fn {name, [value]} -> {name, value} end)

    children = Enum.flat_map(children, &compile_node/1)
    [{:el, tag, static_attrs, dynamic_attrs, attr_slots, children}]
  end

  # Text without slots never joins its neighbours, so it is collapsed once
  # here; text with slots is joined with the dynamic values on every render.
  defp compile_node(text) when is_binary(text) do
    case split(text) do
      [text] when is_binary(text) -> Enum.map(to_node(text), &{:text, &1})
      parts -> parts
    end
  end

  defp compile_node(_comment), do: []

  defp split(text) do
    @slot
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn part ->
      case Regex.run(@slot, part) do
        [^part, i] -> {:slot, slot(i)}
        _ -> part
      end
    end)
  end

  defp slot(i), do: String.to_integer(i)

  defp slots_in(template) do
    template
    |> Enum.flat_map(fn
      {:slot, i} ->
        [i]

      {:el, _, _, dynamic_attrs, attr_slots, children} ->
        attr_slots ++
          for({_, parts} <- dynamic_attrs, {:slot, i} <- parts, do: i) ++
          slots_in(children)

      _text ->
        []
    end)
    |> Enum.sort()
  end
end
