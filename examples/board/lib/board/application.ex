defmodule Board.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Board.View], strategy: :one_for_one, name: Board.Supervisor)
  end
end
