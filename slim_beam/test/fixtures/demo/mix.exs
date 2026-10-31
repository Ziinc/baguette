defmodule Demo.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo,
      version: "0.1.0",
      deps: [{:demo_dep, path: "../demo_dep"}, {:slim_beam, path: "../../..", runtime: false}],
      releases: [demo: [steps: [:assemble, &SlimBeam.step/1], slim_beam: slim_beam()]]
    ]
  end

  def application, do: [mod: {Demo.Application, []}, extra_applications: [:logger]]

  # The tests choose the options.
  defp slim_beam do
    {options, _} = Code.eval_string(System.get_env("SLIM_BEAM", "[]"))
    options
  end
end
