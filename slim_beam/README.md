# SlimBeam

A `mix release` step that trims unused BEAM code and files from a release.

```elixir
def project do
  [
    releases: [
      my_app: [
        steps: [:assemble, &SlimBeam.step/1],
        slim_beam: [keep: [modules: [MyDep.Plugin]]]
      ]
    ],
    deps: [{:slim_beam, path: "...", runtime: false}]
  ]
end
```

Nothing happens unless a release lists the step. It only changes the
assembled release directory, so dev and test builds stay as they are.

## What it removes

| Part | Default | Option |
| --- | --- | --- |
| Dependency modules that nothing reaches | on | `apps:`, `keep:`, `purge: false` |
| `lib/*/src`, `lib/*/include`, `lib/*/doc` | on | `prune: [globs]` adds more |

Every run writes `releases/<vsn>/slim_beam.json`: sizes before and after
(total, per top-level directory, per app) and each removed path with its
reason (`unreachable` or `prune: <glob>`).

### Module purge

A module reaches every module whose name is an atom in it, in its atom table
or its literals. Calls, `apply/3` targets, child specs, a consolidated
protocol's `impl_for` and a module returned from a function all count. The
release keeps a module when something reaches it from these roots:

- every module of the project's own apps (the umbrella children too)
- every module of the apps that aren't purged (see `apps:`)
- the `mod` and `env` of every `.app`
- the atoms in `releases/<vsn>/sys.config`, and the modules and atoms that
  `runtime.exs` names (read without running it)
- `keep: [modules: [...]]`

Then it rewrites each `.app` file's `modules` and the `primLoad` lists in
the `releases/<vsn>/*.script` files, and regenerates the `.boot` files.

`apps:` chooses which apps may lose modules:

- `:deps` (default): the project's dependencies. OTP, `elixir` and `logger`
  stay whole, because they dispatch on names they compute.
- `:all`: every app but the project's own. Test the release well before you
  rely on it.
- a list of apps.

`keep: [apps: [...]]` keeps apps whole.

A module that is reached only by a computed name (`Module.concat/1`,
`String.to_atom/1`, a name read from a file) is purged. Add it to `keep: [modules: [...]]`.

## Test check

```elixir
# test/test_helper.exs
ExUnit.after_suite(&SlimBeam.Check.loaded!/1)
ExUnit.start()
```

After the suite runs, the check plans the purge over the test build's code
paths, using the release's options. If the tests loaded a module the release
would purge, it prints the module and exits 1, so that module belongs in
`keep:`. In place of `sys.config`, it reads every `config/**/*.exs` without
running it. With several releases, name one:
`&SlimBeam.Check.loaded!(&1, release: :my_app)`.
