defmodule Counter.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    plan = Counter.CLI.plan(Baguette.CLI.matches())
    Supervisor.start_link(children(plan), strategy: :one_for_one, name: Counter.Supervisor)
  end

  # The counter window, or a command: its view must not start, as rendering
  # is what opens the window, and the command ends the app itself.
  @doc false
  def children(:window), do: [Counter.Store, {Counter.View, theme: Counter.Theme}]

  def children(command),
    do: [Counter.Store, {Task, fn -> Counter.CLI.run(command) end}]
end
