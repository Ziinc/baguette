defmodule Baguette.Components do
  @moduledoc """
  Function components for a set of native components, generated from the
  manifest the host writes (`baguette_host --manifest`).

      defmodule MyApp.Kit do
        use Baguette.Components, manifest: "priv/components/kit.json", prefix: "kit-"
      end

  Each component becomes a function named after its tag without the prefix
  (`kit-progress-bar` is `progress_bar/1`), with an `attr` per attribute in
  the manifest, so templates are checked when they compile:

      import MyApp.Kit
      <.badge variant="danger" pill>Failed</.badge>

  `phx-*` bindings, `aria-*`, `id` and `class` pass through on every
  component. The module recompiles when the manifest changes.

  The manifest records the GPUI and gpui-kit versions its set was built
  against and a hash of it all. When the native host starts, it compares
  the hash of every set compiled into Elixir (`compiled/0`) with its own,
  and refuses to run with a set that differs.
  """

  import Phoenix.Component, only: [sigil_H: 2, dynamic_tag: 1, render_slot: 1]

  defmacro __using__(opts) do
    manifest = opts |> Keyword.fetch!(:manifest) |> Path.expand(Path.dirname(__CALLER__.file))
    prefix = Keyword.get(opts, :prefix, "")

    %{"version" => 2, "set" => set, "hash" => hash, "components" => components} =
      manifest |> File.read!() |> JSON.decode!()

    defs = for component <- components, do: define(component, prefix)

    quote do
      use Phoenix.Component
      @external_resource unquote(manifest)

      @doc "The components in the manifest, as the host describes them."
      def __manifest__, do: unquote(Macro.escape(components))

      @doc "The component set's name and its manifest's hash."
      def __set__, do: {unquote(set), unquote(hash)}

      unquote_splicing(defs)
    end
  end

  defp define(%{"tag" => tag} = component, prefix) do
    name =
      tag |> String.replace_prefix(prefix, "") |> String.replace("-", "_") |> String.to_atom()

    attrs = Enum.map(component["attrs"] || [], &attr/1)

    slot =
      if component["children"],
        do: quote(do: slot(:inner_block)),
        else: nil

    quote do
      @doc unquote(component["doc"] || "")
      unquote_splicing(attrs)
      attr(:rest, :global, include: ~w(phx-value-*))
      unquote(slot)

      # Phoenix.Component's own `def`, which attaches the attrs above.
      Phoenix.Component.Declarative.def(unquote(name)(assigns),
        do: Baguette.Components.__render__(unquote(tag), assigns)
      )
    end
  end

  defp attr(%{"name" => name, "type" => type} = spec) do
    name = String.to_atom(name)
    opts = [doc: spec["doc"], required: spec["required"] == true]

    {type, opts} =
      case type do
        "boolean" -> {:boolean, Keyword.put(opts, :default, false)}
        "number" -> {:any, opts}
        "string" -> {:string, opts}
        "enum" -> {:string, Keyword.put(opts, :values, spec["values"])}
      end

    opts = if opts[:required], do: Keyword.delete(opts, :default), else: opts
    quote do: attr(unquote(name), unquote(type), unquote(opts))
  end

  @doc """
  Every component set compiled into the loaded applications, as set name
  to manifest hash: what the native host checks against its own sets.
  """
  @spec compiled() :: %{String.t() => String.t()}
  def compiled do
    for {app, _, _} <- Application.loaded_applications(),
        module <- Application.spec(app, :modules) || [],
        Code.ensure_loaded?(module),
        function_exported?(module, :__set__, 0),
        into: %{},
        do: module.__set__()
  end

  @doc false
  def __render__(tag, assigns) do
    attrs =
      assigns
      |> Map.drop([:__changed__, :__given__, :inner_block, :rest])
      |> Enum.reject(fn {_, value} -> value in [nil, false] end)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.merge(assigns.rest)

    assigns = %{tag: tag, attrs: attrs, inner_block: assigns[:inner_block] || []}

    ~H"""
    <.dynamic_tag tag_name={@tag} {@attrs}>{render_slot(@inner_block)}</.dynamic_tag>
    """
  end
end
