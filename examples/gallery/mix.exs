defmodule Gallery.MixProject do
  use Mix.Project

  def project do
    [
      app: :gallery,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:baguette, path: "../.."}],
      releases: [
        gallery: [
          steps: [:assemble, &Baguette.Release.package/1],
          baguette: [
            components: ["gpui-kit"],
            window: [title: "Gallery", width: 640, height: 860]
          ]
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Gallery.Application, []}]
  end
end
