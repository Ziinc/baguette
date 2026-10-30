defmodule Baguette.CanvasTest do
  use ExUnit.Case, async: true
  import Phoenix.Component, only: [sigil_H: 2]

  test "a canvas's shapes reach the host as its children, in order" do
    assigns = %{points: "0,0 10,10 20,5"}

    tree =
      Baguette.Tree.from_rendered(~H"""
      <canvas class="w-32 h-16">
        <rect x="0" y="0" width="10" height="20" rx="2" class="fill-primary" />
        <circle cx="5" cy="5" r="3" class="fill-danger" />
        <path d="M 0 0 L 10 10 Z" class="stroke-primary" stroke-width="2" />
        <polyline points={@points} class="stroke-muted" />
      </canvas>
      """)

    assert %{"t" => "canvas", "c" => shapes} = tree
    assert Enum.map(shapes, & &1["t"]) == ~w(rect circle path polyline)
    assert Enum.all?(shapes, &(&1["c"] == []))
    assert Enum.at(shapes, 3)["a"]["points"] == "0,0 10,10 20,5"
  end
end
