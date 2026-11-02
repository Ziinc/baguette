defmodule Baguette.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ziinc/baguette"

  def project do
    [
      app: :baguette,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # test/fixtures holds projects with tests of their own.
      test_load_filters: [
        &(&1 =~ ~r"_test\.exs$" and not String.starts_with?(&1, "test/fixtures/"))
      ],
      test_ignore_filters: [~r"^test/fixtures/"],
      deps: deps(),
      description: "Native GPUI applications written in Elixir.",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  # `mix docs`, which `mix hex.publish` runs. The README links to the examples
  # and its GIF on GitHub, so the links work on hexdocs too.
  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "docs/native-api.md": [title: "Native API"]],
      groups_for_modules: [
        Views: [Baguette.View, Baguette.Components, Baguette.Kit, Baguette.Theme],
        Platform: [Baguette.App, Baguette.Clipboard, Baguette.Menu, Baguette.Window],
        Testing: [Baguette.Test, Baguette.Playwright],
        Releases: [Baguette.Release, ~r/^Baguette\.Release\./]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Baguette.Application, []}]
  end

  # The NIF and the default host come precompiled, with their checksums. The
  # sources ship too, for releases that build them (Baguette.Release).
  defp package do
    host = ~w(src build.rs Cargo.toml capabilities dist icons tauri.conf.json package.json
              package-lock.json)

    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib priv/components priv/host.sha256 priv/liberlang.sha256 scripts mix.exs README.md LICENSE
           .formatter.exs checksum-Elixir.Baguette.Native.exs native/Cargo.toml
           native/Cargo.lock native/baguette_abi native/baguette_nif) ++
          Enum.map(host, &"native/baguette_host/#{&1}")
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The NIF is precompiled (Baguette.Native.Precompiled). Rustler builds
      # it from source: in a checkout or a git dependency, which have no
      # checksums, or with BAGUETTE_BUILD_NIF.
      {:rustler_precompiled, "~> 0.8"},
      {:rustler, "~> 0.38", runtime: false},
      {:phoenix_live_view, "~> 1.2"},
      {:floki, "~> 0.38"},
      # Baguette.Playwright: end-to-end tests through gpui-playwright.
      {:playwright_ex, "~> 0.15", optional: true},
      {:websockex, "~> 0.4", optional: true},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end
end
