defmodule SlimBeam do
  @moduledoc """
  A `mix release` step that trims unused BEAM code and files from a release.

      releases: [
        my_app: [
          steps: [:assemble, &SlimBeam.step/1],
          slim_beam: [safelist: [modules: [MyDep.Plugin]]]
        ]
      ]

  Nothing changes unless a release lists the step, and only the release
  directory is touched: dev and test builds are never changed.

  ## Module purge

  Drops the `.beam` files of dependencies that nothing in the release can
  reach (see `SlimBeam.Plan`), then rewrites each `.app` file's `modules` and
  the boot scripts. The roots are the project's own apps, every `.app`'s
  `mod` and `env`, the atoms in `sys.config` and `runtime.exs`, and the
  safelist.

    * `:apps` - which apps may lose modules: `:deps` (default) for the
      project's dependencies, `:all` for every app but the project's own, or
      a list. OTP, `elixir` and `logger` dispatch by name all over, so
      `:deps` leaves them whole.
    * `:safelist` - `[modules: [...], apps: [...]]`: modules to keep with all
      they reach, and apps to keep whole. A module reached only by a computed
      name (`Module.concat/1`, `String.to_atom/1`) belongs here.
    * `purge: false` turns the purge off.

  ## ERTS trim

  `erts: [keep: ["erl_child_setup", "inet_gethost"]]` keeps only those
  executables in `erts-*/bin` and drops `erts-*/include`, `lib`, `doc` and
  `man`. Off by default: without `beam.smp` and `erlexec` the release's own
  `bin/<name>` script can no longer start it. It is for hosts that embed the
  BEAM and start the release themselves.

  ## File pruning

  Removes `lib/*/src`, `lib/*/include` and `lib/*/doc`, and whatever matches
  the globs in `prune: ["lib/*/priv/static/*.map"]`, relative to the
  release root.

  ## Report

  The step writes `releases/<vsn>/slim_beam.json`: sizes before and after,
  and each file removed with the reason (see `SlimBeam.Report`).

  ## Test check

  `ExUnit.after_suite(&SlimBeam.Check.loaded!/1)` in `test_helper.exs` fails
  `mix test` when the suite loads a module the release would purge (see
  `SlimBeam.Check`).
  """

  alias SlimBeam.Report

  @doc "The release step."
  @spec step(Mix.Release.t()) :: Mix.Release.t()
  def step(%Mix.Release{} = release) do
    opts = release.options[:slim_beam] || []
    before = Report.sizes(release.path)
    purged = if Keyword.get(opts, :purge, true), do: SlimBeam.Purge.run(release, opts), else: []

    removed =
      purged ++
        SlimBeam.Erts.run(release.path, opts[:erts] || []) ++
        SlimBeam.Prune.run(release.path, opts[:prune] || [])

    after_ = Report.sizes(release.path)
    report = Path.join(release.version_path, "slim_beam.json")
    Report.write!(report, before, after_, removed)

    Mix.shell().info([
      :green,
      "* slim_beam ",
      :reset,
      "#{Report.format_bytes(before.total)} -> #{Report.format_bytes(after_.total)}, ",
      "#{length(purged)} modules purged (#{Path.relative_to(report, release.path)})"
    ])

    release
  end

  @doc """
  The apps of `apps` that may lose modules under `opts` (see `:apps` and
  `:safelist`). `project_apps` are never purged.
  """
  @spec purgeable([atom()], [atom()], keyword()) :: [atom()]
  def purgeable(apps, project_apps, opts) do
    candidates =
      case Keyword.get(opts, :apps, :deps) do
        :deps -> Map.keys(Mix.Project.deps_paths())
        :all -> apps
        list when is_list(list) -> list
      end

    keep = project_apps ++ (get_in(opts, [:safelist, :apps]) || [])
    Enum.filter(apps, &(&1 in candidates and &1 not in keep))
  end

  @doc "The project's own apps: the umbrella's children, or the project app."
  @spec project_apps() :: [atom()]
  def project_apps do
    if Mix.Project.umbrella?(),
      do: Map.keys(Mix.Project.apps_paths()),
      else: [Mix.Project.config()[:app]]
  end

  @doc "The safelisted modules in `opts`."
  @spec safelisted_modules(keyword()) :: [module()]
  def safelisted_modules(opts), do: get_in(opts, [:safelist, :modules]) || []
end
