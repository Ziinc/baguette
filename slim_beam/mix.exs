defmodule SlimBeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :slim_beam,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: [],
      description: "A mix release step that trims unused BEAM code and files from a release."
    ]
  end

  def application, do: [extra_applications: [:mix]]
end
