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
      deps: deps(),
      description: "Native GPUI applications written in Elixir.",
      source_url: @source_url,
      package: [licenses: ["MIT"], links: %{"GitHub" => @source_url}]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Baguette.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:rustler, "~> 0.38"},
      {:phoenix_live_view, "~> 1.2"},
      {:floki, "~> 0.38"},
      # Baguette.Playwright: end-to-end tests through gpui-playwright.
      {:playwright_ex, "~> 0.15", optional: true},
      {:websockex, "~> 0.4", optional: true}
    ]
  end
end
