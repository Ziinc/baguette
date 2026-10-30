defmodule Board.View do
  @moduledoc "A card to drag around, tied to a fixed point by a line."
  use Baguette.View

  def mount(_args), do: {:ok, %{x: 40, y: 40, lifts: 0}}

  def render(assigns) do
    ~H"""
    <div class="relative size-full bg-[#f8fafc]">
      <line x1="20" y1="20" x2={@x} y2={@y} class="stroke-[#64748b]" />
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
