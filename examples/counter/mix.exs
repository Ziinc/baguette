defmodule Counter.MixProject do
  use Mix.Project

  def project do
    [
      app: :counter,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:baguette, path: "../.."}],
      releases: [
        counter: [
          baguette: [
            cli: [
              description: "A counter that can also add numbers without a window",
              subcommands: [
                sum: [
                  description: "Prints the sum of two numbers and exits",
                  args: [
                    [name: "a", index: 1, takes_value: true, required: true],
                    [name: "b", index: 2, takes_value: true, required: true]
                  ]
                ]
              ]
            ]
          ],
          steps: [
            :assemble,
            &Baguette.Release.package/1,
            &Baguette.Release.bundle/1,
            &Baguette.Release.ios/1
          ]
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Counter.Application, []}]
  end
end
