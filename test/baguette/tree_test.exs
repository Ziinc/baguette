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

  defmodule Templates do
    use Phoenix.Component

    attr(:label, :string)
    slot(:inner_block)

    def badge(assigns) do
      ~H"""
      <span class="badge" aria-label={@label}>{render_slot(@inner_block)} !</span>
      """
    end

    def page(assigns) do
      ~H"""
      <div class={"p-2 #{@tone}"} hidden={@hidden} {@rest}>
        {@a} {@b}<text>Count:   {@count}</text>
        <button :for={item <- @items} phx-click="pick" phx-value-id={item}>#{item}</button>
        <.badge :if={@badge} label={@a}>{@b}</.badge>
        {@maybe}
        <p>{@html}</p>
      </div>
      """
    end
  end

  defp both(assigns) do
    rendered = Templates.page(assigns)
    {Tree.from_rendered(rendered), rendered |> Phoenix.HTML.Safe.to_iodata() |> Tree.from_html()}
  end

  @assigns %{
    tone: "bg-primary",
    hidden: false,
    rest: %{"data-x" => "1"},
    a: "Tom & \"Jerry\" <3",
    b: "it's",
    count: 7,
    items: [1, 2],
    badge: true,
    maybe: nil,
    html: "plain"
  }

  test "the template cache builds the same tree as parsing the HTML" do
    for assigns <- [
          @assigns,
          %{@assigns | hidden: true, items: [], badge: false, maybe: "here", rest: %{}},
          %{@assigns | a: "", b: "", count: 0}
        ] do
      {cached, parsed} = both(assigns)
      assert cached == parsed
    end

    rendered = Templates.page(@assigns)
    assert is_list(:persistent_term.get({Tree, rendered.fingerprint}))
  end

  test "raw HTML in a dynamic falls back to parsing the whole render" do
    {cached, parsed} = both(%{@assigns | html: Phoenix.HTML.raw("<b>bold</b> &nbsp;x")})
    assert cached == parsed
    assert %{"c" => [%{"t" => "b", "c" => ["bold"]} | _]} = List.last(cached["c"])
  end
end
