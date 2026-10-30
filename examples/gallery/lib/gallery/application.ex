defmodule Gallery.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Gallery.View], strategy: :one_for_one, name: Gallery.Supervisor)
  end
end
