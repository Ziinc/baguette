defmodule IosNifDemoRust.MixProject do
  use Mix.Project

  def project do
    [app: :ios_nif_demo_rust, version: "0.1.0", deps: [{:rustler, "~> 0.38"}]]
  end
end
