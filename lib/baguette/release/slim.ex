defmodule Baguette.Release.Slim do
  @moduledoc """
  Trims a release down to the code it runs. `Baguette.Release.package/1`
  runs it before anything else, so every Baguette release is slimmed. Only
  the assembled release directory changes; dev and test builds don't.

  ## Module purge

  Drops every `.beam` that nothing in the release can reach (see
  `Baguette.Release.Slim.Plan`), then rewrites each `.app` file's `modules`
  and the boot scripts. The roots are the project's own apps, every `.app`'s
  `mod` and `env`, the atoms in `sys.config` and `runtime.exs`, and `keep:`.

  Every app may lose modules except these, which stay whole:

    * `kernel` and `stdlib`, which OTP needs to run. Kernel picks its inet,
      distribution and logger handler modules by names it builds at runtime.
    * `crypto`, `public_key`, `ssl`, `inets` and `asn1`, which do the same
      for ciphers, key formats and HTTP handlers.
    * `logger` and every `telemetry*` app, so logging and telemetry work
      whatever the release attaches at runtime.

  Everything else, Elixir, IEx and debugging tools such as `recon` or
  `runtime_tools` included, keeps only what the release reaches. Keep more
  with the release's options:

      baguette: [keep: [modules: [MyDep.Plugin], apps: [:recon]]]

  `modules:` keeps modules, with all they reach; a module the release
  reaches only by a computed name (`Module.concat/1`, `String.to_atom/1`)
  belongs here. `apps:` keeps apps whole. `purge: false` turns the purge off.

  ## File pruning

  Removes `lib/*/src`, `lib/*/include` and `lib/*/doc`, and whatever matches
  the globs in `prune: ["lib/*/priv/static/*.map"]`, relative to the
  release root.

  ## Report

  Writes `releases/<vsn>/slim.json`: sizes before and after, and each file
  removed with the reason (see `Baguette.Release.Slim.Report`).

  ## Test check

  `Baguette.Release.Slim.Check.start()` in `test_helper.exs` fails
  `mix test` when the suite loads a module the release would purge (see
  `Baguette.Release.Slim.Check`).
  """

  alias Baguette.Release.Slim.{Prune, Purge, Report}

  # Kept whole: see the moduledoc.
  @core_apps [:kernel, :stdlib, :crypto, :public_key, :ssl, :inets, :asn1, :logger]

  @doc "Slims `release` in place."
  @spec run(Mix.Release.t()) :: Mix.Release.t()
  def run(%Mix.Release{} = release) do
    opts = options(release)
    before = Report.sizes(release.path)
    purged = if Keyword.get(opts, :purge, true), do: Purge.run(release, opts), else: []
    removed = purged ++ Prune.run(release.path, opts[:prune] || [])

    after_ = Report.sizes(release.path)
    report = Path.join(release.version_path, "slim.json")
    Report.write!(report, before, after_, removed)

    Mix.shell().info([
      :green,
      "* slimmed ",
      :reset,
      "#{Report.format_bytes(before.total)} -> #{Report.format_bytes(after_.total)}, ",
      "#{length(purged)} modules purged (#{Path.relative_to(report, release.path)})"
    ])

    release
  end

  @doc "The slimming options of a release, or of its config: its `baguette:` options."
  @spec options(Mix.Release.t() | keyword()) :: keyword()
  def options(%Mix.Release{options: options}), do: options(options)
  def options(options), do: options[:baguette] || []

  @doc """
  The apps of `apps` that may lose modules: all but the project's own, the
  core apps and those `opts` keeps.
  """
  @spec purgeable([atom()], [atom()], keyword()) :: [atom()]
  def purgeable(apps, project_apps, opts) do
    keep = project_apps ++ @core_apps ++ (get_in(opts, [:keep, :apps]) || [])
    Enum.reject(apps, &(&1 in keep or String.starts_with?(Atom.to_string(&1), "telemetry")))
  end

  @doc "The project's own apps: the umbrella's children, or the project app."
  @spec project_apps() :: [atom()]
  def project_apps do
    if Mix.Project.umbrella?(),
      do: Map.keys(Mix.Project.apps_paths()),
      else: [Mix.Project.config()[:app]]
  end

  @doc "The modules `opts` keeps."
  @spec kept_modules(keyword()) :: [module()]
  def kept_modules(opts), do: get_in(opts, [:keep, :modules]) || []
end
