defmodule DemoDep.MixProject do
  use Mix.Project

  def project, do: [app: :demo_dep, version: "0.1.0", deps: []]
  def application, do: [mod: {DemoDep.Application, []}]
end
