defmodule Baguette.HostTest do
  use ExUnit.Case, async: true
  alias Baguette.Host

  @frame %{
    "theme" => %{"primary" => "#000"},
    "root" => %{"t" => "text", "a" => %{}, "c" => ["1"]}
  }

  test "the first frame goes whole" do
    assert Host.wire(nil, @frame) == @frame
  end

  test "later frames go as patches to what the host has" do
    next = put_in(@frame["root"]["c"], ["2"])

    assert Host.wire(@frame, Map.put(next, "lists", %{"jobs" => %{"start" => 0, "rows" => []}})) ==
             %{
               "patch" => [%{"op" => "replace", "at" => [0], "node" => "2"}],
               "lists" => %{"jobs" => %{"start" => 0, "rows" => []}}
             }
  end

  test "a new theme goes whole" do
    next = put_in(@frame["theme"]["primary"], "#fff")
    assert Host.wire(@frame, next) == next
  end
end
