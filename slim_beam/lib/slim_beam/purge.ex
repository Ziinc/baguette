defmodule SlimBeam.Purge do
  @moduledoc false
  # Removes the modules `SlimBeam.Plan` finds unreachable from an assembled
  # release, then rewrites the `.app` files and boot scripts that list them.

  alias SlimBeam.{Files, Plan}

  @doc "Purges `release`. Returns the files removed, as report entries."
  def run(%Mix.Release{} = release, opts) do
    plan = plan(release, opts)

    removed =
      for {module, app} <- Enum.sort(plan.purge) do
        path = Path.join(ebin(release, app), "#{module}.beam")
        Files.remove!(release.path, Path.relative_to(path, release.path), "unreachable")
      end

    by_app = Enum.group_by(Map.keys(plan.purge), &plan.purge[&1])
    Enum.each(by_app, fn {app, modules} -> rewrite_app(release, app, modules) end)
    rewrite_scripts(release.version_path, MapSet.new(Map.keys(plan.purge)))
    removed
  end

  @doc "The plan for an assembled release."
  def plan(%Mix.Release{} = release, opts) do
    apps =
      for {app, _} <- release.applications,
          File.dir?(ebin(release, app)),
          do: {app, ebin(release, app)}

    consolidated = Path.join(release.version_path, "consolidated")

    Plan.build(apps,
      purgeable: SlimBeam.purgeable(Keyword.keys(apps), SlimBeam.project_apps(), opts),
      roots: config_atoms(release.version_path) ++ SlimBeam.kept_modules(opts),
      consolidated: if(File.dir?(consolidated), do: consolidated)
    )
  end

  defp ebin(release, app) do
    vsn = release.applications[app][:vsn]
    Path.join([release.path, "lib", "#{app}-#{vsn}", "ebin"])
  end

  # The atoms in `sys.config`, and the modules and atoms `runtime.exs` names.
  defp config_atoms(version_path) do
    sys_config =
      case :file.consult(Path.join(version_path, "sys.config")) do
        {:ok, terms} -> Plan.atoms(terms)
        _ -> []
      end

    sys_config ++ Plan.exs_atoms(Path.join(version_path, "runtime.exs"))
  end

  defp rewrite_app(release, app, modules) do
    path = Path.join(ebin(release, app), "#{app}.app")
    {:ok, [{:application, ^app, props}]} = :file.consult(path)
    props = Keyword.update(props, :modules, [], &(&1 -- modules))
    File.write!(path, consultable({:application, app, props}))
  end

  # Embedded mode loads every module a boot script lists, so the scripts lose
  # the purged modules and the boot files are made again from them.
  defp rewrite_scripts(version_path, purged) do
    for script <- Path.wildcard(Path.join(version_path, "*.script")) do
      {:ok, [{:script, info, instructions}]} = :file.consult(script)

      instructions =
        Enum.map(instructions, fn
          {:primLoad, modules} -> {:primLoad, Enum.reject(modules, &MapSet.member?(purged, &1))}
          other -> other
        end)

      File.write!(script, consultable({:script, info, instructions}))
      :ok = :systools.script2boot(String.to_charlist(Path.rootname(script)))
    end
  end

  defp consultable(term), do: :io_lib.format(~c"%% coding: utf-8~n~tp.~n", [term])
end
