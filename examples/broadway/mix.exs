defmodule Firehose.MixProject do
  use Mix.Project

  def project do
    [
      app: :firehose,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:baguette, path: "../.."}, {:broadway, "~> 1.2"}],
      releases: [
        firehose: [
          steps: [:assemble, &Baguette.Release.package/1],
          baguette: [window: [title: "Firehose", width: 960, height: 640]]
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Firehose.Application, []}]
  end
end
