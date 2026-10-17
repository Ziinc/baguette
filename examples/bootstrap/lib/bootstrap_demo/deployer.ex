defmodule BootstrapDemo.Deployer do
  @moduledoc """
  Rolls out services one step per tick and tells subscribers about every
  change. `search` fails at 60% on its first attempt, so the demo shows a
  failure and a retry.
  """
  use GenServer

  @services ~w(api web search payments)
  @tick 120

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Subscribes the caller to `{:deployer, services}` messages; returns the services."
  def subscribe, do: GenServer.call(__MODULE__, :subscribe)

  def deploy(name), do: GenServer.cast(__MODULE__, {:deploy, name})
  def deploy_all, do: Enum.each(@services, &deploy/1)
  def reset, do: GenServer.cast(__MODULE__, :reset)

  @impl true
  def init(opts) do
    tick = Keyword.get(opts, :tick, @tick)
    :timer.send_interval(tick, :tick)
    {:ok, %{services: fresh(), subscribers: MapSet.new(), failed_once: MapSet.new()}}
  end

  @impl true
  def handle_call(:subscribe, {pid, _}, state) do
    Process.monitor(pid)
    {:reply, state.services, update_in(state.subscribers, &MapSet.put(&1, pid))}
  end

  @impl true
  def handle_cast({:deploy, name}, state) do
    state =
      update_service(state, name, fn
        %{status: status} = s when status in [:idle, :failed, :live] ->
          %{s | status: :deploying, progress: 0}

        s ->
          s
      end)

    {:noreply, notify(state)}
  end

  def handle_cast(:reset, state) do
    {:noreply, notify(%{state | services: fresh(), failed_once: MapSet.new()})}
  end

  @impl true
  def handle_info(:tick, state) do
    if Enum.any?(state.services, &(&1.status == :deploying)) do
      {:noreply, state |> advance() |> notify()}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _, :process, pid, _}, state) do
    {:noreply, update_in(state.subscribers, &MapSet.delete(&1, pid))}
  end

  defp advance(state) do
    Enum.reduce(state.services, state, fn
      %{status: :deploying, name: name, progress: progress}, state ->
        next = progress + 5

        cond do
          name == "search" and next >= 60 and name not in state.failed_once ->
            state
            |> update_in([:failed_once], &MapSet.put(&1, name))
            |> update_service(name, &%{&1 | status: :failed, progress: next})

          next >= 100 ->
            update_service(state, name, &%{&1 | status: :live, progress: 100})

          true ->
            update_service(state, name, &%{&1 | progress: next})
        end

      _, state ->
        state
    end)
  end

  defp update_service(state, name, fun) do
    %{state | services: Enum.map(state.services, &if(&1.name == name, do: fun.(&1), else: &1))}
  end

  defp notify(state) do
    for pid <- state.subscribers, do: send(pid, {:deployer, state.services})
    state
  end

  defp fresh, do: for(name <- @services, do: %{name: name, status: :idle, progress: 0})
end
