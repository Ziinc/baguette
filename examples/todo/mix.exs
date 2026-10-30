defmodule Todo.MixProject do
  use Mix.Project

  def project do
    [
      app: :todo,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:baguette, path: "../.."}],
      releases: [
        todo: [
          steps: [:assemble, &Baguette.Release.package/1],
          baguette: [window: [title: "Todos", width: 520, height: 560]]
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Todo.Application, []}]
  end
end
