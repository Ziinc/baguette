defmodule SlimBeam.Plan do
  @moduledoc """
  Which modules a release can reach, and which it can do without.

  A module reaches every module whose name is an atom in it: in its atom
  table (calls, `apply/3` targets, pattern matches) or in its literals
  (child specs, maps, lists). That over-approximates calls on purpose: a
  module named anywhere is kept, which covers protocol implementations in a
  consolidated `impl_for`, behaviours handed over as arguments and modules
  named in config.

  The roots are every module of the apps that may not be purged, the `mod`
  and `env` of every `.app` file and the `:roots` given. Without
  consolidated protocols, every protocol implementation is a root too,
  because an unconsolidated protocol finds its implementations by name.
  """

  defstruct modules: %{}, keep: MapSet.new(), purge: %{}, reached_by: %{}

  @typedoc """
    * `modules` - every module seen, with its app
    * `keep` - the modules reached
    * `purge` - the modules of purgeable apps that nothing reaches, with their app
    * `reached_by` - for each kept module, `:root` or the module that reached it
  """
  @type t :: %__MODULE__{
          modules: %{module() => atom()},
          keep: MapSet.t(module()),
          purge: %{module() => atom()},
          reached_by: %{module() => module() | :root}
        }

  @doc """
  Builds the plan for `apps`, a keyword list of app names to their `ebin`
  directories.

  ## Options

    * `:purgeable` - the apps that may lose modules (default: none)
    * `:roots` - more atoms to start from, such as those in `sys.config`
    * `:consolidated` - the directory of consolidated protocols, whose
      modules replace the originals
  """
  @spec build([{atom(), Path.t()}], keyword()) :: t()
  def build(apps, opts \\ []) do
    purgeable = MapSet.new(Keyword.get(opts, :purgeable, []))
    consolidated = opts[:consolidated]

    {modules, paths, app_atoms} =
      Enum.reduce(apps, {%{}, %{}, []}, fn {app, ebin}, {modules, paths, atoms} ->
        beams = Path.wildcard(Path.join(ebin, "*.beam"))
        names = Enum.map(beams, &module_name/1)

        {Map.merge(modules, Map.new(names, &{&1, app})),
         Map.merge(paths, Map.new(Enum.zip(names, beams))), app_atoms(ebin, app) ++ atoms}
      end)

    paths = Map.merge(paths, consolidated_paths(consolidated, modules))
    chunks = fn module -> chunks(Map.fetch!(paths, module)) end

    impls =
      if consolidated,
        do: [],
        else: for({m, app} <- modules, app in purgeable, impl?(chunks.(m)), do: m)

    roots =
      for({m, app} <- modules, app not in purgeable, do: m) ++
        Enum.filter(
          app_atoms ++ Keyword.get(opts, :roots, []) ++ impls,
          &Map.has_key?(modules, &1)
        )

    reached_by = reach(Enum.uniq(roots), modules, chunks)
    keep = MapSet.new(Map.keys(reached_by))

    purge =
      for {m, app} <- modules,
          app in purgeable,
          not MapSet.member?(keep, m),
          into: %{},
          do: {m, app}

    %__MODULE__{modules: modules, keep: keep, purge: purge, reached_by: reached_by}
  end

  defp reach(roots, modules, chunks) do
    walk(roots, modules, chunks, Map.new(roots, &{&1, :root}))
  end

  defp walk([], _modules, _chunks, seen), do: seen

  defp walk([module | rest], modules, chunks, seen) do
    {found, seen} =
      module
      |> chunks.()
      |> Map.fetch!(:atoms)
      |> Enum.reduce({[], seen}, fn atom, {found, seen} ->
        if Map.has_key?(modules, atom) and not Map.has_key?(seen, atom),
          do: {[atom | found], Map.put(seen, atom, module)},
          else: {found, seen}
      end)

    walk(found ++ rest, modules, chunks, seen)
  end

  defp module_name(beam), do: beam |> Path.basename(".beam") |> String.to_atom()

  defp consolidated_paths(nil, _modules), do: %{}

  defp consolidated_paths(dir, modules) do
    for beam <- Path.wildcard(Path.join(dir, "*.beam")),
        module = module_name(beam),
        Map.has_key?(modules, module),
        into: %{},
        do: {module, beam}
  end

  # The atoms of an app's `mod` and `env`, but not of its `modules` list.
  defp app_atoms(ebin, app) do
    case :file.consult(Path.join(ebin, "#{app}.app")) do
      {:ok, [{:application, ^app, props}]} -> atoms([props[:mod], props[:env]])
      _ -> []
    end
  end

  @doc "The atoms a `.beam` file names, in its atom table and its literals."
  @spec atoms_in(Path.t()) :: [atom()]
  def atoms_in(path), do: chunks(path).atoms

  defp chunks(path) do
    {:ok, {_, chunks}} =
      :beam_lib.chunks(String.to_charlist(path), [:atoms, :exports, ~c"LitT"], [
        :allow_missing_chunks
      ])

    chunks = Map.new(chunks)
    atoms = for {_, atom} <- chunks[:atoms], do: atom
    %{atoms: atoms ++ literal_atoms(chunks[~c"LitT"]), exports: chunks[:exports]}
  end

  defp impl?(%{exports: exports}), do: {:__impl__, 1} in exports

  defp literal_atoms(:missing_chunk), do: []

  defp literal_atoms(<<size::32, data::binary>>) do
    <<_count::32, entries::binary>> = if size == 0, do: data, else: :zlib.uncompress(data)
    entries |> literals([]) |> atoms()
  end

  defp literals(<<>>, acc), do: acc

  defp literals(<<size::32, term::binary-size(size), rest::binary>>, acc),
    do: literals(rest, [:erlang.binary_to_term(term) | acc])

  @doc false
  def atoms(term), do: term |> atoms([]) |> Enum.uniq()

  defp atoms(atom, acc) when is_atom(atom), do: [atom | acc]
  defp atoms([head | tail], acc), do: atoms(tail, atoms(head, acc))
  defp atoms(tuple, acc) when is_tuple(tuple), do: atoms(Tuple.to_list(tuple), acc)
  defp atoms(%{} = map, acc), do: atoms(Map.to_list(map), acc)
  defp atoms(_other, acc), do: acc
end
