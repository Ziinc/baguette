defmodule Firehose.Dashboard do
  @moduledoc """
  The whole Broadway pipeline, live: every stage's rate and load, batches,
  acks and failures, a throughput history and the latest events. It samples
  `Firehose.Stats` ten times a second; the pipeline never talks to it.
  """
  use Baguette.View
  require Logger

  @sample 100
  # Rates are averaged over this many samples (half a second), since batches
  # and acks arrive in bursts.
  @window 5
  @history 48
  @rates [50, 100, 200, 400, 800, 1600]

  def mount(_args) do
    :timer.send_interval(@sample, :sample)
    Firehose.Pipeline.set_chaos(0)

    snapshot = Firehose.Stats.snapshot()

    {:ok,
     %{
       snaps: [snapshot],
       last: snapshot,
       now: snapshot,
       history: List.duplicate(0, @history),
       span: 0,
       samples: 0,
       mobile: Baguette.mobile?(),
       tick: 0,
       rate: 400,
       paused: false,
       chaos: 0
     }}
  end

  def handle_info(:sample, assigns) do
    now = Firehose.Stats.snapshot()
    snaps = Enum.take([now | assigns.snaps], @window + 1)
    last = List.last(snaps)
    span = length(snaps) - 1
    acked = per_second(now.acked + now.failed - last.acked - last.failed, span)

    # A heartbeat for logs (logcat on Android), every two seconds.
    if rem(assigns.samples, 20) == 0 do
      Logger.info("firehose: acked=#{now.acked} failed=#{now.failed} dropped=#{now.dropped}")
    end

    {:noreply,
     %{
       assigns
       | snaps: snaps,
         samples: assigns.samples + 1,
         span: span,
         last: last,
         now: now,
         history: Enum.drop(assigns.history ++ [acked], 1),
         tick: if(assigns.paused, do: assigns.tick, else: assigns.tick + 1)
     }}
  end

  def handle_event("pause", _, assigns) do
    Firehose.Producer.pause(!assigns.paused)
    {:noreply, %{assigns | paused: !assigns.paused}}
  end

  def handle_event("rate", %{"step" => step}, assigns) do
    i = Enum.find_index(@rates, &(&1 == assigns.rate)) + String.to_integer(step)
    rate = Enum.at(@rates, i |> max(0) |> min(length(@rates) - 1))
    Firehose.Producer.set_rate(rate)
    Logger.info("firehose: rate=#{rate}")
    {:noreply, %{assigns | rate: rate}}
  end

  def handle_event("chaos", _, assigns) do
    chaos = if assigns.chaos == 0, do: 10, else: 0
    Firehose.Pipeline.set_chaos(chaos)
    Logger.info("firehose: chaos=#{chaos}")
    {:noreply, %{assigns | chaos: chaos}}
  end

  def render(assigns) do
    %{now: now, last: last, span: span} = assigns
    peak = Enum.max([1 | assigns.history])

    assigns =
      Map.merge(assigns, %{
        produced: per_second(now.produced - last.produced, span),
        throughput: List.last(assigns.history),
        peak: peak,
        processors:
          for i <- 0..(Firehose.Stats.processors() - 1) do
            busy = Enum.at(now.busy, i) - Enum.at(last.busy, i)

            %{
              index: i,
              rate: per_second(Enum.at(now.processed, i) - Enum.at(last.processed, i), span),
              total: Enum.at(now.processed, i),
              load: min(round(busy / max(span * @sample * 10, 1)), 100)
            }
          end,
        batchers:
          for b <- Firehose.Stats.batchers() do
            %{count: count, messages: messages} = now.batches[b]
            prev = last.batches[b]
            batches = count - prev.count

            %{
              name: b,
              rate: per_second(batches, span),
              size: if(batches > 0, do: div(messages - prev.messages, batches), else: 0),
              max: if(b == :warehouse, do: 25, else: 5),
              total: count
            }
          end
      })

    ~H"""
    <div :if={not @mobile} class="size-full flex-col gap-3 p-4 bg-bg text-fg">
      <div class="flex-row items-center justify-between">
        <.heading />
        <.controls paused={@paused} rate={@rate} chaos={@chaos} />
      </div>

      <div class="flex-row gap-2 h-[300px]">
        <.stage title="Producer" subtitle="synthetic events">
          <.producer produced={@produced} now={@now} />
        </.stage>
        <.flow tick={@tick} />
        <.stage title="Processors" subtitle="concurrency 4">
          <.processor :for={p <- @processors} p={p} />
        </.stage>
        <.flow tick={@tick} />
        <.stage title="Batchers" subtitle="by destination">
          <.batcher :for={b <- @batchers} b={b} />
        </.stage>
        <.flow tick={@tick} />
        <.stage title="Acknowledged" subtitle="end of the line">
          <.acks now={@now} />
        </.stage>
      </div>

      <div class="flex-row gap-4 flex-1">
        <.throughput history={@history} throughput={@throughput} peak={@peak} />
        <div class="flex-col gap-1 p-3 rounded-lg bg-panel border border-edge w-[320px]">
          <text class="text-sm font-bold">Latest batched events</text>
          <div :for={e <- @now.recent} class="flex-row items-center gap-2">
            <div class={"size-2 rounded-full bg-#{e.kind}"} />
            <text class="text-xs w-14 text-muted">#{e.id}</text>
            <text class="text-xs w-12">{e.kind}</text>
            <text class="text-xs w-10 text-right">${e.amount}</text>
            <text class="text-xs text-muted">→ {e.batcher}</text>
          </div>
        </div>
      </div>
    </div>

    <div :if={@mobile} class="size-full flex-col gap-3 px-4 pt-12 pb-6 bg-bg text-fg">
      <.heading />
      <.controls paused={@paused} rate={@rate} chaos={@chaos} />
      <div class="flex-row gap-2">
        <.stage title="Producer" subtitle="synthetic events">
          <.producer produced={@produced} now={@now} />
        </.stage>
        <.stage title="Acknowledged" subtitle="end of the line">
          <.acks now={@now} />
        </.stage>
      </div>
      <div class="flex-row gap-2">
        <.stage title="Processors" subtitle="concurrency 4">
          <.processor :for={p <- @processors} p={p} />
        </.stage>
        <.stage title="Batchers" subtitle="by destination">
          <.batcher :for={b <- @batchers} b={b} />
        </.stage>
      </div>
      <.throughput history={@history} throughput={@throughput} peak={@peak} />
    </div>
    """
  end

  defp heading(assigns) do
    ~H"""
    <div class="flex-col gap-1">
      <text class="text-2xl font-bold">Firehose</text>
      <text class="text-sm text-muted">A Broadway pipeline, drawn live by GPUI from Elixir</text>
    </div>
    """
  end

  attr(:paused, :boolean, required: true)
  attr(:rate, :integer, required: true)
  attr(:chaos, :integer, required: true)

  defp controls(assigns) do
    ~H"""
    <div class="flex-row items-center gap-2">
      <.control phx-click="pause" aria-label={if @paused, do: "Resume", else: "Pause"}>
        {if @paused, do: "▶ Resume", else: "❚❚ Pause"}
      </.control>
      <.control phx-click="rate" phx-value-step="-1" aria-label="Slower">−</.control>
      <text class="w-20 text-center font-bold" aria-label="Rate">{@rate}/s</text>
      <.control phx-click="rate" phx-value-step="1" aria-label="Faster">+</.control>
      <.control phx-click="chaos" aria-label="Chaos" active={@chaos > 0}>
        Chaos {@chaos}%
      </.control>
    </div>
    """
  end

  attr(:produced, :integer, required: true)
  attr(:now, :map, required: true)

  defp producer(assigns) do
    ~H"""
    <.metric value={@produced} unit="events/s" />
    <.bar label="buffer" value={@now.buffered} max={2000} color="accent" />
    <text class="text-xs text-muted">produced {@now.produced}</text>
    <text class="text-xs text-muted">dropped {@now.dropped}</text>
    """
  end

  attr(:p, :map, required: true)

  defp processor(assigns) do
    ~H"""
    <div class="flex-col gap-1 p-2 rounded-md bg-panel-hi">
      <div class="flex-row justify-between">
        <text class="text-xs text-muted">processor {@p.index}</text>
        <text class="text-xs font-bold">{@p.rate}/s</text>
      </div>
      <.bar value={@p.load} max={100} color={load_color(@p.load)} />
    </div>
    """
  end

  attr(:b, :map, required: true)

  defp batcher(assigns) do
    ~H"""
    <div class="flex-col gap-1 p-2 rounded-md bg-panel-hi">
      <div class="flex-row justify-between">
        <text class="text-sm font-bold">{@b.name}</text>
        <text class="text-xs text-muted">{@b.rate}/s</text>
      </div>
      <.bar label={"fill #{@b.size}/#{@b.max}"} value={@b.size} max={@b.max} color="click" />
      <text class="text-xs text-muted">{@b.total} batches</text>
    </div>
    """
  end

  attr(:now, :map, required: true)

  defp acks(assigns) do
    ~H"""
    <div class="flex-col gap-1 p-2 rounded-md bg-panel-hi">
      <text class="text-xs text-muted">acked</text>
      <text class="text-2xl font-bold text-ok">{@now.acked}</text>
    </div>
    <div class="flex-col gap-1 p-2 rounded-md bg-panel-hi">
      <text class="text-xs text-muted">failed</text>
      <text class={"text-2xl font-bold #{if @now.failed > 0, do: "text-bad", else: "text-muted"}"}>
        {@now.failed}
      </text>
    </div>
    """
  end

  attr(:history, :list, required: true)
  attr(:throughput, :integer, required: true)
  attr(:peak, :integer, required: true)

  defp throughput(assigns) do
    ~H"""
    <div class="flex-col gap-2 p-3 rounded-lg bg-panel border border-edge flex-1">
      <div class="flex-row justify-between">
        <text class="text-sm font-bold">Throughput</text>
        <text class="text-sm text-muted">{@throughput} msg/s · peak {@peak}</text>
      </div>
      <div class="flex-row items-end gap-[2px] flex-1">
        <div
          :for={v <- @history}
          class={"flex-1 rounded-sm bg-accent h-[#{max(round(v / @peak * 100), 2)}%]"}
        />
      </div>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:subtitle, :string, required: true)
  slot(:inner_block)

  defp stage(assigns) do
    ~H"""
    <div class="flex-col gap-2 p-3 rounded-lg bg-panel border border-edge flex-1 min-w-0">
      <div class="flex-col">
        <text class="text-sm font-bold">{@title}</text>
        <text class="text-xs text-muted">{@subtitle}</text>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr(:value, :integer, required: true)
  attr(:unit, :string, required: true)

  defp metric(assigns) do
    ~H"""
    <div class="flex-col">
      <text class="text-3xl font-bold">{@value}</text>
      <text class="text-xs text-muted">{@unit}</text>
    </div>
    """
  end

  attr(:value, :integer, required: true)
  attr(:max, :integer, required: true)
  attr(:color, :string, required: true)
  attr(:label, :string, default: nil)

  defp bar(assigns) do
    assigns = Map.put(assigns, :pct, min(round(assigns.value / max(assigns.max, 1) * 100), 100))

    ~H"""
    <div class="flex-col gap-1">
      <text :if={@label} class="text-xs text-muted">{@label}</text>
      <div class="w-full h-2 rounded-full bg-edge overflow-hidden">
        <div class={"h-full rounded-full bg-#{@color} w-[#{@pct}%]"} />
      </div>
    </div>
    """
  end

  # Three dots between stages; the lit one walks right while events flow.
  attr(:tick, :integer, required: true)

  defp flow(assigns) do
    ~H"""
    <div class="flex-row items-center justify-center gap-1 w-10">
      <div
        :for={i <- 0..2}
        class={"size-2 rounded-full #{if rem(@tick, 3) == i, do: "bg-accent", else: "bg-edge"}"}
      />
    </div>
    """
  end

  attr(:active, :boolean, default: false)
  attr(:rest, :global, include: ~w(phx-click phx-value-step aria-label))
  slot(:inner_block)

  defp control(assigns) do
    ~H"""
    <button
      class={"px-3 py-1 rounded-md border border-edge text-sm #{if @active, do: "bg-bad text-bg", else: "bg-panel-hi hover:bg-edge"}"}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp per_second(_delta, 0), do: 0
  defp per_second(delta, samples), do: round(delta * 1000 / (@sample * samples))

  defp load_color(load) when load > 85, do: "bad"
  defp load_color(load) when load > 60, do: "warn"
  defp load_color(_), do: "ok"
end
