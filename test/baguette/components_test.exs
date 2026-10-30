defmodule Baguette.ComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.Component, only: [sigil_H: 2]

  alias Baguette.Tree

  alias Baguette.Test.Kit
  import Kit

  test "each component in the manifest becomes a function component" do
    assert Kit.__manifest__() |> Enum.map(& &1["tag"]) == ["kit-badge", "kit-progress-bar"]
    assert function_exported?(Kit, :badge, 1)
    assert function_exported?(Kit, :progress_bar, 1)
  end

  test "renders the native tag with its attributes, events and children" do
    assigns = %{}

    tree =
      Tree.from_rendered(~H"""
      <div>
        <.badge variant="danger" pill>Failed</.badge>
        <.progress_bar value={40} phx-click="open" phx-value-id="7" />
      </div>
      """)

    assert %{
             "c" => [
               %{
                 "t" => "kit-badge",
                 "a" => %{"variant" => "danger", "pill" => _},
                 "c" => ["Failed"]
               },
               %{
                 "t" => "kit-progress-bar",
                 "a" => %{"value" => "40", "phx-click" => "open", "phx-value-id" => "7"},
                 "c" => []
               }
             ]
           } = tree
  end

  test "leaves out boolean attributes that are off" do
    assigns = %{}
    tree = Tree.from_rendered(~H"<.badge>New</.badge>")
    assert tree == %{"t" => "kit-badge", "a" => %{}, "c" => ["New"]}
  end

  test "the manifest's attribute types are checked when templates compile" do
    {_, diagnostics} =
      Code.with_diagnostics(fn ->
        # Collected as diagnostics; kept off the test output.
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule Baguette.ComponentsTest.Bad do
            use Phoenix.Component
            import Baguette.Test.Kit

            def render(assigns) do
              ~H\"\"\"
              <.badge variant="purple" size="xl">x</.badge>
              <.progress_bar />
              \"\"\"
            end
          end
          """)
        end)
      end)

    warnings = Enum.map_join(diagnostics, "\n", & &1.message)

    assert warnings =~
             ~s(attribute "variant" in component Baguette.Test.Kit.badge/1 must be one of)

    assert warnings =~ ~s(undefined attribute "size")
    assert warnings =~ ~s(missing required attribute "value")
  end

  test "documents each component from the manifest" do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Kit)

    assert Enum.any?(docs, fn
             {{:function, :badge, 1}, _, _, %{"en" => doc}, _} -> doc =~ "A short status label."
             _ -> false
           end)
  end
end
