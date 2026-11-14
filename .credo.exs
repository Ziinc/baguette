# `mix credo --strict`, run by CI. The formatter owns layout, so only checks
# about design and readability matter here. Each check turned off below is
# one the code base does not follow, or one that fights the formatter.
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/", "mix.exs"],
        # test/fixtures holds projects of their own; examples/ are separate
        # Mix projects, linted with their own formatter run in CI.
        excluded: [~r"/_build/", ~r"/deps/", ~r"test/fixtures/"]
      },
      checks: %{
        disabled: [
          # Layout is `mix format`'s (line length 98); long strings and
          # heredocs are fine.
          {Credo.Check.Readability.MaxLineLength, []},
          # Fully qualified `Baguette.*` calls read better than an alias for
          # each one used once.
          {Credo.Check.Design.AliasUsage, []},
          # Large cases and render pipelines are inherent to the tree, patch
          # and release code; splitting them hides the flow.
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.Nesting, []},
          # Release helpers pass many arguments by design.
          {Credo.Check.Refactor.FunctionArity, []},
          # Sigils and fixtures use unseparated numbers on purpose.
          {Credo.Check.Readability.LargeNumbers, []},
          # TODO comments are notes, not failures.
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Design.TagFIXME, []}
        ]
      }
    }
  ]
}
