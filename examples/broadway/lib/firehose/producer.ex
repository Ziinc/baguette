defmodule Firehose.Producer do
  @moduledoc """
  A synthetic event stream: orders, clicks, signups and refunds at a rate
  the dashboard controls. Events beyond what the pipeline asks for wait in a
  bounded buffer; past that they are dropped, as a real firehose would.
  """
  use GenStage

  @behaviour Broadway.Acknowledger
  @tick 50
  @max_buffer 2_000
  @kinds [{"order", 50}, {"click", 30}, {"signup", 15}, {"refund", 5}]

  def set_rate(rate), do: send_producer({:rate, rate})
  def pause(paused?), do: send_producer({:pause, paused?})

  defp send_producer(msg) do
    for name <- Broadway.producer_names(Firehose.Pipeline), do: send(name, msg)
    :ok
  end

  @impl GenStage
  def init(opts) do
    :timer.send_interval(@tick, :tick)

    {:producer,
     %{
       rate: Keyword.get(opts, :rate, 400),
       paused: false,
       demand: 0,
       queue: :queue.new(),
       n: 0,
       seq: 0
     }}
  end

  @impl GenStage
  def handle_demand(demand, state), do: dispatch(%{state | demand: state.demand + demand})

  @impl GenStage
  def handle_info(:tick, %{paused: true} = state), do: {:noreply, [], state}

  def handle_info(:tick, state) do
    count = div(state.rate * @tick, 1000)

    {events, seq} =
      Enum.map_reduce(1..count//1, state.seq, fn _, seq -> {event(seq + 1), seq + 1} end)

    Firehose.Stats.produced(count)
    queue = Enum.reduce(events, state.queue, &:queue.in/2)
    overflow = max(:queue.len(queue) - @max_buffer, 0)
    {_dropped, queue} = :queue.split(overflow, queue)
    Firehose.Stats.dropped(overflow)
    dispatch(%{state | queue: queue, seq: seq})
  end

  def handle_info({:rate, rate}, state), do: {:noreply, [], %{state | rate: rate}}
  def handle_info({:pause, paused?}, state), do: {:noreply, [], %{state | paused: paused?}}

  defp dispatch(state) do
    take = min(state.demand, :queue.len(state.queue))
    {out, queue} = :queue.split(take, state.queue)
    Firehose.Stats.buffered(:queue.len(queue))

    messages =
      for data <- :queue.to_list(out) do
        %Broadway.Message{data: data, acknowledger: {__MODULE__, :firehose, nil}}
      end

    {:noreply, messages, %{state | queue: queue, demand: state.demand - take}}
  end

  defp event(seq) do
    roll = :rand.uniform(100)

    {kind, _} =
      Enum.reduce_while(@kinds, roll, fn {kind, weight}, left ->
        if left <= weight, do: {:halt, {kind, weight}}, else: {:cont, left - weight}
      end)

    %{id: seq, kind: kind, amount: :rand.uniform(500)}
  end

  @impl Broadway.Acknowledger
  def ack(:firehose, successful, failed) do
    Firehose.Stats.acked(length(successful))
    Firehose.Stats.failed(length(failed))
  end
end
