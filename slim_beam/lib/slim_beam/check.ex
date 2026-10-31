defmodule SlimBeam.Check do
  @moduledoc """
  Fails `mix test` when the suite loads a module the release would purge.

      # test/test_helper.exs
      ExUnit.after_suite(&SlimBeam.Check.loaded!/1)
      ExUnit.start()

  It plans the purge over the current environment's code paths for the
  release's apps, with the release's `slim_beam:` options. The roots stand
  in for `sys.config` with every module and atom named in `config/**/*.exs`,
  read without running them. A module the tests load but the plan purges is
  one the release reaches only by a computed name: add it to the release's `keep:` list.

  With several releases, name one: `&SlimBeam.Check.loaded!(&1, release: :my_app)`.
  """

  alias SlimBeam.Plan

  @doc "The `ExUnit.after_suite/1` callback. Makes `mix test` exit 1 on a violation."
  @spec loaded!(map(), keyword()) :: :ok
  def loaded!(_results, opts \\ []) do
    case purged_loaded(opts) do
      [] ->
        :ok

      modules ->
        IO.puts(:stderr, message(modules))
        System.at_exit(fn _ -> exit({:shutdown, 1}) end)
        :ok
    end
  end

  @doc "The loaded modules the release would purge, with their apps."
  @spec purged_loaded(keyword()) :: [{module(), atom()}]
  def purged_loaded(opts \\ []) do
    %{purge: purge} = plan(opts)
    for {module, _} <- :code.all_loaded(), app = purge[module], do: {module, app}
  end

  @doc "The release's plan over the current code paths."
  @spec plan(keyword()) :: Plan.t()
  def plan(opts \\ []) do
    config = Mix.Project.config()
    release = Mix.Release.from_config!(opts[:release], config, [])
    slim = release.options[:slim_beam] || []

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
      purgeable: SlimBeam.purgeable(Keyword.keys(apps), SlimBeam.project_apps(), slim),
      roots: config_atoms ++ SlimBeam.kept_modules(slim),
      consolidated:
        if(config[:consolidate_protocols] && File.dir?(consolidated), do: consolidated)
    )
  end

  defp message(modules) do
    list =
      Enum.map_join(Enum.sort(modules), "\n", fn {m, app} -> "  * #{inspect(m)} (#{app})" end)

    """

    SlimBeam: the tests loaded modules the release would purge:

    #{list}

    The release reaches them only by a computed name. Keep them with the
    release's keep list:

        slim_beam: [keep: [modules: [#{Enum.map_join(Enum.sort(modules), ", ", &inspect(elem(&1, 0)))}]]]
    """
  end
end
