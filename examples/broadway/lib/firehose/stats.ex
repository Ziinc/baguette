defmodule Firehose.Stats do
  @moduledoc """
  Lock-free counters every pipeline stage bumps, read by the dashboard.

  Stages write with `:counters` (no messages, no contention), so measuring
  the pipeline does not slow it down. `snapshot/0` reads everything at once.
  """

  @processors 4
  @batchers [:warehouse, :alerts]

  # Slots in the counters array.
  @produced 1
  @dropped 2
  @buffered 3
  @acked 4
  @failed 5
  @processed 6
  @busy @processed + @processors
  @batches @busy + @processors
  @batched @batches + length(@batchers)
  @size @batched + length(@batchers)

  def processors, do: @processors
  def batchers, do: @batchers

  def init do
    :persistent_term.put(__MODULE__, :counters.new(@size, [:write_concurrency]))
    :persistent_term.put({__MODULE__, :recent}, :ets.new(__MODULE__, [:public, :ordered_set]))
    :ok
  end

  def reset do
    ref = ref()
    for i <- 1..@size, do: :counters.put(ref, i, 0)
    :ets.delete_all_objects(recent_table())
    :ok
  end

  def produced(n), do: :counters.add(ref(), @produced, n)
  def dropped(n), do: :counters.add(ref(), @dropped, n)
  def buffered(n), do: :counters.put(ref(), @buffered, n)
  def acked(n), do: :counters.add(ref(), @acked, n)
  def failed(n), do: :counters.add(ref(), @failed, n)

  def processed(index, micros) do
    :counters.add(ref(), @processed + index, 1)
    :counters.add(ref(), @busy + index, micros)
  end

  def batch(batcher, size, sample) do
    i = Enum.find_index(@batchers, &(&1 == batcher))
    :counters.add(ref(), @batches + i, 1)
    :counters.add(ref(), @batched + i, size)
    :ets.insert(recent_table(), {System.unique_integer([:monotonic]), batcher, sample})
  end

  @doc "All counters, plus the last `n` messages to reach a batch."
  def snapshot(n \\ 6) do
    ref = ref()
    get = &:counters.get(ref, &1)

    %{
      produced: get.(@produced),
      dropped: get.(@dropped),
      buffered: get.(@buffered),
      acked: get.(@acked),
      failed: get.(@failed),
      processed: for(i <- 0..(@processors - 1), do: get.(@processed + i)),
      busy: for(i <- 0..(@processors - 1), do: get.(@busy + i)),
      batches:
        for {b, i} <- Enum.with_index(@batchers), into: %{} do
          {b, %{count: get.(@batches + i), messages: get.(@batched + i)}}
        end,
      recent: recent(n)
    }
  end

  defp recent(n) do
    table = recent_table()
    trim(table, n)

    table
    |> :ets.tab2list()
    |> Enum.reverse()
    |> Enum.map(fn {_, batcher, msg} -> Map.put(msg, :batcher, batcher) end)
  end

  defp trim(table, n) do
    if :ets.info(table, :size) > n do
      :ets.delete(table, :ets.first(table))
      trim(table, n)
    end
  end

  defp ref, do: :persistent_term.get(__MODULE__)
  defp recent_table, do: :persistent_term.get({__MODULE__, :recent})
end
