defmodule Firehose.Pipeline do
  @moduledoc """
  The Broadway pipeline the dashboard draws: one producer, four processors
  that "enrich" each event, and two batchers. Refunds over 250 go to
  `alerts`; everything else is written to the `warehouse` in batches.
  """
  use Broadway

  alias Broadway.Message

  def start_link(opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [module: {Firehose.Producer, opts}, concurrency: 1],
      processors: [default: [concurrency: Firehose.Stats.processors(), max_demand: 10]],
      batchers: [
        warehouse: [concurrency: 2, batch_size: 25, batch_timeout: 400],
        alerts: [concurrency: 1, batch_size: 5, batch_timeout: 800]
      ]
    )
  end

  @doc "The share of messages processors fail on purpose (0..100)."
  def set_chaos(percent), do: :persistent_term.put({__MODULE__, :chaos}, percent)
  def chaos, do: :persistent_term.get({__MODULE__, :chaos}, 0)

  @impl true
  def handle_message(_processor, %Message{data: event} = message, _context) do
    started = System.monotonic_time(:microsecond)
    # Stand-in for real work: a lookup that takes a few milliseconds.
    Process.sleep(2 + :rand.uniform(6))
    index = processor_index()
    Firehose.Stats.processed(index, System.monotonic_time(:microsecond) - started)

    cond do
      :rand.uniform(100) <= chaos() ->
        Message.failed(message, :enrichment_failed)

      event.kind == "refund" and event.amount > 250 ->
        Message.put_batcher(message, :alerts)

      true ->
        Message.put_batcher(message, :warehouse)
    end
  end

  @impl true
  def handle_batch(batcher, messages, info, _context) do
    Process.sleep(div(info.size, 2) + 3)
    Firehose.Stats.batch(batcher, info.size, List.last(messages).data)
    messages
  end

  # Processors are named `<pipeline>.Broadway.Processor_default_<index>`.
  defp processor_index do
    with nil <- Process.get(:firehose_index) do
      {:registered_name, name} = Process.info(self(), :registered_name)
      index = name |> Atom.to_string() |> String.split("_") |> List.last() |> String.to_integer()
      Process.put(:firehose_index, index)
      index
    end
  end
end
