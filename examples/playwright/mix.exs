defmodule Tally.MixProject do
  use Mix.Project

  def project do
    [
      app: :tally,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps(),
      releases: [
        # The `playwright` host feature serves Playwright's protocol from the
        # app when GPUI_PLAYWRIGHT is set (see test/playwright_test.exs).
        tally: [
          steps: [:assemble, &Baguette.Release.package/1],
          baguette: [
            host_features: ["playwright"],
            window: [title: "Tally", width: 420, height: 360]
          ]
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Tally.Application, []}]
  end

  defp deps do
    [
      {:baguette, path: "../.."},
      # Playwright's Elixir client, over WebSocket to the app itself.
      {:playwright_ex, "~> 0.15", only: :test},
      {:websockex, "~> 0.4", only: :test}
    ]
  end
end
