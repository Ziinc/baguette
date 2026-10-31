defmodule Todo.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([{Todo.View, theme: Todo.Theme}],
      strategy: :one_for_one,
      name: Todo.Supervisor
    )
  end
end
