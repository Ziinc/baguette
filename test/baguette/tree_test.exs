defmodule Baguette.TreeTest do
  use ExUnit.Case, async: true
  import Phoenix.Component, only: [sigil_H: 2]

  alias Baguette.Tree

  test "converts HEEx into nodes, dropping whitespace between elements" do
    assigns = %{count: 3}

    tree =
      Tree.from_rendered(~H"""
      <div class="flex-col gap-2">
        <text class="text-xl">Count:   {@count}</text>
        <button phx-click="inc" phx-value-by="2">+</button>
      </div>
      """)

    assert tree == %{
             "t" => "div",
             "a" => %{"class" => "flex-col gap-2"},
             "c" => [
               %{"t" => "text", "a" => %{"class" => "text-xl"}, "c" => ["Count: 3"]},
               %{
                 "t" => "button",
                 "a" => %{"phx-click" => "inc", "phx-value-by" => "2"},
                 "c" => ["+"]
               }
             ]
           }
  end

  test "wraps several roots in a div and returns nil for nothing" do
    assert %{"t" => "div", "c" => [%{"t" => "a"}, %{"t" => "b"}]} =
             Tree.from_html("<a></a><b></b>")

    assert Tree.from_html("  <!-- nothing --> ") == nil
  end
end
