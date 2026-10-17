defmodule Counter.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Counter.Store,
      {Counter.View, theme: Counter.Theme}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Counter.Supervisor)
  end
end
