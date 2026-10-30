defmodule Baguette.E2E.TodoPlaywrightTest do
  # The todo release (examples/todo) built with the host's `playwright`
  # feature: native text inputs, forms, checkboxes and list roles.
  use ExUnit.Case, async: false
  alias Baguette.Playwright

  @moduletag :playwright

  @app Path.expand("../../examples/todo/_build/prod/rel/todo/bin/todo_app", __DIR__)

  setup do
    # No port: the app picks a free one and reports it in its endpoint file.
    app = Playwright.start_app!(@app)
    on_exit(fn -> Playwright.stop_app(app) end)
    %{page: Playwright.connect!(app), app: app}
  end

  test "the endpoint comes from the app's endpoint file", %{app: app} do
    assert app.endpoint =~ ~r{^ws://127\.0\.0\.1:\d+/}
  end

  test "fill and Enter submit the form; the view's reset clears the input", %{page: page} do
    assert :ok = Playwright.fill(page, "Title", "Buy milk")
    assert Playwright.input_value(page, "Title") == "Buy milk"
    assert :ok = Playwright.press(page, "Title", "Enter")

    assert :ok = Playwright.await_text(page, "1 of 1 left")
    assert Playwright.count(page, role: "listitem") == 1
    assert Playwright.input_value(page, "Title") == ""
  end

  test "a submit button submits the form", %{page: page} do
    Playwright.fill(page, "Title", "Walk dog")
    Playwright.click(page, "Add")
    assert :ok = Playwright.await_text(page, "1 of 1 left")
    assert Playwright.checked?(page, "Walk dog") == false
  end

  test "fill scrolls an input below its container's fold into view and types there",
       %{page: page} do
    Playwright.fill(page, "Title", "keep me")
    assert :ok = Playwright.fill(page, "Note", "noted")

    assert Playwright.input_value(page, "Note") == "noted"
    assert :ok = Playwright.await_text(page, "Note: noted")
    assert Playwright.input_value(page, "Title") == "keep me"
  end

  test "checkboxes check and uncheck", %{page: page} do
    for title <- ["Buy milk", "Walk dog"] do
      Playwright.fill(page, "Title", title)
      Playwright.press(page, "Title", "Enter")
    end

    assert :ok = Playwright.await_text(page, "2 of 2 left")
    assert :ok = Playwright.check(page, "Buy milk")
    assert :ok = Playwright.await_text(page, "1 of 2 left")
    assert Playwright.checked?(page, "Buy milk")

    assert :ok = Playwright.uncheck(page, "Buy milk")
    assert :ok = Playwright.await_text(page, "2 of 2 left")
  end

  test "roles and names show in the accessibility tree", %{page: page} do
    Playwright.fill(page, "Title", "Buy milk")
    Playwright.press(page, "Title", "Enter")
    assert :ok = Playwright.await_text(page, "1 of 1 left")

    snapshot = Playwright.aria_snapshot(page)
    assert snapshot =~ ~s(heading "Todos")
    assert snapshot =~ ~s(textbox "Title")
    assert snapshot =~ ~s(list "Todos")
    assert snapshot =~ "listitem"
    assert snapshot =~ ~s(checkbox "Buy milk")

    assert Playwright.count(page, role: "checkbox") == 1
    assert Playwright.text_content(page, role: "heading") == "Todos"
    Playwright.click(page, role: "button", name: "Delete Buy milk")
    assert :ok = Playwright.await_text(page, "0 of 0 left")
  end

  test "gpui-kit components take their colours from the app's theme", %{page: page} do
    Playwright.fill(page, "Title", "Buy milk")
    Playwright.press(page, "Title", "Enter")
    Playwright.check(page, "Buy milk")
    assert :ok = Playwright.await_text(page, "0 of 1 left")

    %{"x" => x, "y" => y, "width" => w, "height" => h} =
      Playwright.bounding_box(page, role: "checkbox", name: "Buy milk")

    png = Path.join(System.tmp_dir!(), "baguette-todo-theme.png")
    File.write!(png, Playwright.screenshot(page))
    # The checked box is filled with the theme's primary (Todo.Theme's teal),
    # not gpui-kit's default near-black: most of its 16px box is that teal.
    teal = Enum.count(pixels(png, x, y, w, h), &close?(&1, {0x0D, 0xB9, 0xB6}))
    assert teal > w * h / 3, "only #{teal} teal pixels in the checkbox"
    assert w > 0
  end

  defp pixels(png, x, y, w, h) do
    crop = "#{round(w)}x#{round(h)}+#{round(x)}+#{round(y)}"
    {out, 0} = System.cmd("convert", [png, "-crop", crop, "txt:-"])

    for [_, hex] <- Regex.scan(~r/#([0-9A-F]{6})/, out) do
      <<r::binary-2, g::binary-2, b::binary-2>> = hex
      {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
    end
  end

  defp close?({r, g, b}, {r2, g2, b2}), do: abs(r - r2) + abs(g - g2) + abs(b - b2) < 40
end
