defmodule Baguette.E2E.BoardPlaywrightTest do
  # The board release (examples/board) built with the host's `playwright`
  # feature: absolute positioning, `phx-drag` and `<line>`.
  use ExUnit.Case, async: false
  alias Baguette.Playwright

  @moduletag :playwright

  @app Path.expand("../../examples/board/_build/prod/rel/board/bin/board_app", __DIR__)

  setup do
    app = Playwright.start_app!(@app, port: 9336)
    on_exit(fn -> Playwright.stop_app(app) end)
    %{page: Playwright.connect!(app)}
  end

  test "the card sits where its classes put it and moves when dragged", %{page: page} do
    assert :ok = Playwright.await_text(page, "At 40,40")
    assert %{"x" => x, "y" => y} = Playwright.bounding_box(page, "Card")
    assert_in_delta x, 40, 1
    assert_in_delta y, 40, 1

    Playwright.drag(page, "Card", 100, 50)
    assert :ok = Playwright.await_text(page, "At 140,90")
    assert %{"x" => x} = Playwright.bounding_box(page, "Card")
    assert_in_delta x, 140, 1
  end

  test "screenshot/1 returns the window as a PNG", %{page: page} do
    assert :ok = Playwright.await_text(page, "At 40,40")
    png = Playwright.screenshot(page)
    assert <<0x89, "PNG", _::binary>> = png
    File.write!(Path.join(System.tmp_dir!(), "baguette-board.png"), png)
  end

  test "a drag goes only to the topmost element under the pointer", %{page: page} do
    assert :ok = Playwright.await_text(page, "Lifts: 0")
    Playwright.drag(page, "Lid", 50, 0)
    assert :ok = Playwright.await_text(page, "Lifts: 1")
    assert :ok = Playwright.await_text(page, "At 40,40")
  end

  test "pressing and releasing without moving is not a drag", %{page: page} do
    assert :ok = Playwright.await_text(page, "Lifts: 0")
    Playwright.drag(page, "Lid", 0, 0)
    Playwright.drag(page, "Lid", 50, 0)
    assert :ok = Playwright.await_text(page, "Lifts: 1")
    assert {:error, _} = Playwright.await_text(page, "Lifts: 2", timeout: 500)
  end

  test "max-w caps a full-width element", %{page: page} do
    assert :ok = Playwright.await_text(page, "Capped")
    assert %{"width" => width} = Playwright.bounding_box(page, "Note")
    assert_in_delta width, 150, 1
  end
end
