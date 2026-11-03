defmodule IosNifDemoC.MixProject do
  use Mix.Project

  def project do
    [
      app: :ios_nif_demo_c,
      version: "0.1.0",
      compilers: [:elixir_make] ++ Mix.compilers(),
      deps: [{:elixir_make, "~> 0.9", runtime: false}]
    ]
  end
end
