# The tests' release for Baguette.Release.Slim. It loads Slim's sources from
# this checkout rather than depending on Baguette, so it needs no
# dependencies fetched or NIFs built.
slim = Path.expand("../../../lib/baguette/release", __DIR__)

for file <- [Path.join(slim, "slim.ex") | Path.wildcard(Path.join(slim, "slim/*.ex"))],
    do: Code.require_file(file)

defmodule Demo.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo,
      version: "0.1.0",
      deps: [{:demo_dep, path: "../slim_demo_dep"}],
      releases: [demo: [steps: [:assemble, &Baguette.Release.Slim.run/1], baguette: options()]]
    ]
  end

  def application, do: [mod: {Demo.Application, []}, extra_applications: [:logger]]

  # The tests choose the options.
  defp options do
    {options, _} = Code.eval_string(System.get_env("SLIM", "[]"))
    options
  end
end
