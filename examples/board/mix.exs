defmodule Board.MixProject do
  use Mix.Project

  def project do
    [
      app: :board,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:baguette, path: "../.."}],
      releases: [
        board: [steps: [:assemble, &Baguette.Release.package/1]]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Board.Application, []}]
  end
end
