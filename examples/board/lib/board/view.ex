defmodule Board.View do
  @moduledoc "A card to drag around, tied to a fixed point by a line."
  use Baguette.View

  def mount(_args), do: {:ok, %{x: 40, y: 40, lifts: 0}}

  def render(assigns) do
    ~H"""
    <div class="relative size-full bg-[#f8fafc]">
      <line x1="20" y1="20" x2={@x} y2={@y} class="stroke-[#64748b]" />
      <line x1="300" y1="40" x2="420" y2="160" curve class="stroke-[#0DB9B6]" />
      <div class="absolute left-[20px] top-[200px] w-[140px] h-[120px] overflow-y-scroll bg-[#ffffff]"
        aria-label="Scroller">
        <div class="flex-col">
          <text :for={i <- 1..30} aria-label={"Item #{i}"}>Item {i}</text>
        </div>
      </div>
      <div class="absolute left-[200px] top-[260px] w-[300px]">
        <div class="w-full max-w-[150px] p-2 bg-[#e2e8f0]" aria-label="Note"><text>Capped</text></div>
      </div>
      <div class={"absolute left-[#{@x}px] top-[#{@y}px] p-3 rounded-md bg-[#ffffff] border"}
        phx-drag="move" aria-label="Card">
        <text>At {@x},{@y}</text>
      </div>
      <%!-- Over the card's right side, so dragging it must not drag the card. --%>
      <div class="absolute left-[100px] top-[45px] p-1 bg-[#fde68a]" phx-drag="lift" aria-label="Lid">
        <text>Lifts: {@lifts}</text>
      </div>
    </div>
    """
  end

  def handle_event("lift", _values, assigns), do: {:noreply, %{assigns | lifts: assigns.lifts + 1}}

  def handle_event("move", %{"dx" => dx, "dy" => dy}, assigns),
    do: {:noreply, %{assigns | x: assigns.x + round(dx), y: assigns.y + round(dy)}}
end
