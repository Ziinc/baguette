defmodule Baguette.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Baguette.Registry},
      Baguette.Host
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Baguette.Supervisor)
  end
end
