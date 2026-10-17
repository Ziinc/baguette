defmodule BootstrapDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :bootstrap_demo,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:baguette, path: "../.."}],
      releases: [
        bootstrap_demo: [
          steps: [:assemble, &Baguette.Release.package/1],
          baguette: [
            host_features: ["bootstrap"],
            window: [title: "Release train", width: 720, height: 560]
          ]
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {BootstrapDemo.Application, []}]
  end
end
