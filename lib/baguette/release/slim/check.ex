defmodule Baguette.Release.Slim.Check do
  @moduledoc """
  Fails `mix test` when the suite loads a module the release would purge.

      # test/test_helper.exs
      Baguette.Release.Slim.Check.start()
      ExUnit.start()

  After the suite it checks the modules the tests loaded. It plans the purge over the
  current environment's code paths for the release's apps, with the
  release's `baguette:` options. The roots stand in for `sys.config` with
  every module and atom named in `config/**/*.exs`, read without running
  them. A module the tests load but the plan purges is one the release
  reaches only by a computed name: add it to the release's `keep:` list.

  Elixir's own apps are left out of the check, because Mix and ExUnit load
  their modules as the suite runs.

  With several releases, name one: `start(release: :my_app)`.
  """

  alias Baguette.Release.Slim
  alias Baguette.Release.Slim.Plan

  # Mix and ExUnit load Elixir's own modules themselves, so the check leaves
  # these apps out.
  @tooling_apps [:elixir, :eex, :iex, :logger, :mix, :ex_unit]

  @doc """
  Checks, after the suite, the modules the tests load. Makes `mix test`
  exit 1 on a violation. Call it in `test_helper.exs`.

  Compiling a project in the test VM loads its modules, so `start/1`
  unloads those the release would purge: a test that uses one loads it
  again. One it can't unload, because a process runs it, is in use already.
  """
  @spec start(keyword()) :: :ok
  def start(opts \\ []) do
    %{purge: purge} = plan(opts)

    in_use =
      for {module, _} <- :code.all_loaded(),
          app = purge[module],
          app not in @tooling_apps,
          not unload(module),
          do: module

    already = MapSet.new(:code.all_loaded(), &elem(&1, 0))
    opts = Keyword.merge(opts, except: already, in_use: in_use)
    ExUnit.after_suite(fn _results -> loaded!(opts) end)
  end

  defp unload(module) do
    :code.delete(module) and :code.soft_purge(module)
  end

  @doc false
  def loaded!(opts) do
    case purged_loaded(opts) do
      [] ->
        :ok

      modules ->
        IO.puts(:stderr, message(modules))
        System.at_exit(fn _ -> exit({:shutdown, 1}) end)
        :ok
    end
  end

  @doc """
  The modules the release would purge that are loaded, but for those in
  `opts[:except]`, or in `opts[:in_use]`, with their apps.
  """
  @spec purged_loaded(keyword()) :: [{module(), atom()}]
  def purged_loaded(opts \\ []) do
    %{purge: purge} = plan(opts)
    except = Keyword.get(opts, :except, MapSet.new())
    loaded = for {module, _} <- :code.all_loaded(), do: module

    for module <- Enum.uniq(loaded ++ Keyword.get(opts, :in_use, [])),
        app = purge[module],
        app not in @tooling_apps,
        not MapSet.member?(except, module),
        do: {module, app}
  end

  @doc "The release's plan over the current code paths."
  @spec plan(keyword()) :: Plan.t()
  def plan(opts \\ []) do
    config = Mix.Project.config()
    release = Mix.Release.from_config!(opts[:release], config, [])
    slim = Slim.options(release)

    apps =
      for {app, props} <- release.applications,
          ebin = Path.join(props[:path], "ebin"),
          File.dir?(ebin),
          do: {app, ebin}

    consolidated = Mix.Project.consolidation_path(config)
    config_dir = config[:config_path] |> Path.expand() |> Path.dirname()

    config_atoms =
      Enum.flat_map(Path.wildcard(Path.join(config_dir, "**/*.exs")), &Plan.exs_atoms/1)

    Plan.build(apps,
      purgeable: Slim.purgeable(Keyword.keys(apps), Slim.project_apps(), slim),
      roots: config_atoms ++ Slim.kept_modules(slim),
      consolidated:
        if(config[:consolidate_protocols] && File.dir?(consolidated), do: consolidated)
    )
  end

  defp message(modules) do
    list =
      Enum.map_join(Enum.sort(modules), "\n", fn {m, app} -> "  * #{inspect(m)} (#{app})" end)

    """

    Baguette: the tests loaded modules the release would purge:

    #{list}

    The release reaches them only by a computed name. Keep them with the
    release's keep list:

        baguette: [keep: [modules: [#{Enum.map_join(Enum.sort(modules), ", ", &inspect(elem(&1, 0)))}]]]
    """
  end
end
