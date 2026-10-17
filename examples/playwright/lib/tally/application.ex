defmodule Tally.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [{Tally.View, theme: Tally.Theme}]
    Supervisor.start_link(children, strategy: :one_for_one, name: Tally.Supervisor)
  end
end
