defmodule Baguette.Release.Scan do
  @moduledoc """
  What a release leaves out of its native host.

  As Tailwind keeps only the classes it finds in your source, a release
  keeps only the host APIs and icons its source uses. One precompiled host
  serves every app (`Baguette.Release.host_source/2`), so this happens when
  the release is packaged, not compiled. It scans
  `lib/**/*.{ex,exs,heex,eex}` by default:

    * `:pick` (native file dialogs) is kept when the source has
      `phx-pick-file` or `phx-pick-save`.
    * `:open_url` is kept when it has `open_url`.
    * Icons: every kebab-case word in the source that names an icon in
      gpui-kit's catalog is copied into the release
      (`releases/<vsn>/icons`). The rest of the 1,830-icon catalog stays
      out; gpui-kit's own component icons are built in.

  The host registers only the kept APIs' plugins, from the `apis` in
  `releases/<vsn>/baguette.json`.

  Release options (`releases: [my_app: [baguette: [...]]]`):

    * `exclude: [:pick, :open_url]` - leave these out even if the source uses them.
    * `scan: false` - scan nothing; keep every API and icon not excluded.
    * `scan: [paths: ["lib/**/*.ex", "deps/my_ui/lib/**/*.ex"]]` - the globs to scan.
    * `safelist: [apis: [:open_url], icons: ["bell"]]` - keep what the source
      only reaches dynamically (`<icon name={@name}>`, `apply/3`).

  Something left out draws nothing and is logged by the host. Under
  `mix test`, `Baguette.Test` raises when a view renders it, so a test
  catches what the scan missed.
  """

  @apis %{open_url: ["open_url"], pick: ["phx-pick-file", "phx-pick-save"]}
  @default_paths ["lib/**/*.{ex,exs,heex,eex}"]

  @type plan :: %{excluded: [atom()], icons: :all | {:only, MapSet.t(String.t())}}

  @doc "The host APIs a release can leave out."
  @spec apis() :: [atom()]
  def apis, do: @apis |> Map.keys() |> Enum.sort()

  @doc "What the release with `options` leaves out, scanning the project at `root`."
  @spec plan(keyword() | map(), Path.t()) :: plan()
  def plan(options, root) do
    opts = get_in(options, [:baguette]) || []
    exclude = Keyword.get(opts, :exclude, [])
    safelist = Keyword.get(opts, :safelist, [])

    for api <- exclude ++ Keyword.get(safelist, :apis, []), api not in apis() do
      raise ArgumentError, "unknown API #{inspect(api)}; can be one of #{inspect(apis())}"
    end

    case Keyword.get(opts, :scan, true) do
      false ->
        %{excluded: Enum.sort(exclude), icons: :all}

      scan ->
        paths =
          if is_list(scan), do: Keyword.get(scan, :paths, @default_paths), else: @default_paths

        source = read(root, paths)

        used =
          for {api, markers} <- @apis, Enum.any?(markers, &String.contains?(source, &1)), do: api

        kept = used ++ Keyword.get(safelist, :apis, [])
        excluded = Enum.uniq((apis() -- kept) ++ exclude) |> Enum.sort()
        icons = MapSet.union(tokens(source), MapSet.new(Keyword.get(safelist, :icons, [])))
        %{excluded: excluded, icons: {:only, icons}}
    end
  end

  defp read(root, paths) do
    paths
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.uniq()
    |> Enum.map_join("\n", &File.read!/1)
  end

  # Candidate icon names: every kebab-case word. The host keeps those that
  # name an icon.
  defp tokens(source) do
    ~r/[a-z][a-z0-9]*(?:-[a-z0-9]+)*/
    |> Regex.scan(source)
    |> Enum.map(&hd/1)
    |> MapSet.new()
  end

  @doc """
  Raises when `tree` renders something `plan` leaves out: an icon the scan
  didn't find, or a picker without `:pick`.
  """
  @spec check!(Baguette.Tree.tree() | nil, plan()) :: :ok
  def check!(%{"a" => attrs} = node, plan) do
    case {node["t"], plan.icons} do
      {"icon", {:only, icons}} ->
        name = attrs["name"]

        unless name in icons,
          do:
            raise(ArgumentError, """
            icon #{inspect(name)} is left out of the release: the source scan didn't \
            find it. Write the name in the source, or add it to the release's \
            `baguette: [safelist: [icons: [#{inspect(name)}]]]`.
            """)

      _ ->
        :ok
    end

    for binding <- ~w(phx-pick-file phx-pick-save),
        Map.has_key?(attrs, binding),
        :pick in plan.excluded do
      raise ArgumentError, "#{binding} needs the :pick API, which this release excludes"
    end

    Enum.each(node["c"] || [], &check!(&1, plan))
  end

  def check!(_text_or_nil, _plan), do: :ok

  @doc false
  # The plan for `mix test`: what the current project's releases leave
  # out, merged, or nil without a Mix project that has releases.
  def current do
    with true <- Code.ensure_loaded?(Mix.Project),
         config when is_list(config) <- Mix.Project.get() && Mix.Project.config(),
         [_ | _] = releases <- config[:releases] || [] do
      key = {__MODULE__, Mix.Project.get()}

      case :persistent_term.get(key, nil) do
        nil ->
          plan = merge(for {_name, options} <- releases, do: plan(options, File.cwd!()))
          :persistent_term.put(key, plan)
          plan

        plan ->
          plan
      end
    else
      _ -> nil
    end
  end

  defp merge(plans) do
    icons =
      if Enum.any?(plans, &(&1.icons == :all)) and Enum.all?(plans, &(&1.icons == :all)),
        do: :all,
        else:
          {:only,
           plans
           |> Enum.flat_map(fn
             %{icons: {:only, icons}} -> [icons]
             _ -> []
           end)
           |> Enum.reduce(&MapSet.intersection/2)}

    %{excluded: plans |> Enum.flat_map(& &1.excluded) |> Enum.uniq() |> Enum.sort(), icons: icons}
  end

  @doc false
  # Raises under `mix test` when the project's releases exclude `api`.
  def ensure!(api) do
    case current() do
      %{excluded: excluded} when is_list(excluded) ->
        if api in excluded,
          do: raise(ArgumentError, "#{inspect(api)} is excluded from this release")

        :ok

      _ ->
        :ok
    end
  end
end
