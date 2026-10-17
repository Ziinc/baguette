defmodule Firehose.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Firehose.Stats.init()

    children = [
      Firehose.Pipeline,
      {Firehose.Dashboard, theme: Firehose.Theme}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Firehose.Supervisor)
  end
end
