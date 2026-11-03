# The iOS dependency-NIF test (ios.yml): an app whose dependencies carry a
# Rustler NIF and an elixir_make NIF, which `Baguette.Release.ios/1` builds
# again for iOS and links into the app.
defmodule IosNifDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :ios_nif_demo,
      version: "0.1.0",
      deps: [
        {:baguette, path: "../../.."},
        {:ios_nif_demo_rust, path: "../ios_nif_demo_rust"},
        {:ios_nif_demo_c, path: "../ios_nif_demo_c"}
      ],
      releases: [
        ios_nif_demo: [
          steps: [:assemble, &Baguette.Release.package/1, &Baguette.Release.ios/1],
          baguette: [identifier: "dev.baguette.iosnifdemo"]
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {IosNifDemo.Application, []}]
end
