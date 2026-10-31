defmodule Baguette.KitTest do
  use ExUnit.Case, async: true
  import Phoenix.Component, only: [sigil_H: 2]
  import Baguette.Kit

  test "gpui-kit's components, from the committed manifest" do
    tags = Enum.map(Baguette.Kit.__manifest__(), & &1["tag"])
    assert "kit-tag" in tags
    assert "kit-progress" in tags
    assert function_exported?(Baguette.Kit, :tag, 1)
    assert function_exported?(Baguette.Kit, :progress, 1)
  end

  test "renders kit tags into the tree" do
    assigns = %{}

    tree =
      Baguette.Tree.from_rendered(~H"""
      <div>
        <.tag variant="danger" pill>Failed</.tag>
        <.progress value={40} aria-label="Upload" class="w-full" />
      </div>
      """)

    assert %{
             "c" => [
               %{"t" => "kit-tag", "a" => %{"variant" => "danger"}, "c" => ["Failed"]},
               %{"t" => "kit-progress", "a" => %{"value" => "40", "aria-label" => "Upload"}}
             ]
           } = tree
  end
end
