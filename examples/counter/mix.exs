defmodule Counter.MixProject do
  use Mix.Project

  def project do
    [
      app: :counter,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:baguette, path: "../.."}],
      releases: [counter: [steps: [:assemble, &Baguette.Release.package/1, &Baguette.Release.bundle/1]]]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Counter.Application, []}]
  end
end
