defmodule Baguette.E2E.GalleryPlaywrightTest do
  # Baguette's native API in a real host: examples/gallery built with the
  # host's `playwright` feature and the gpui-kit component set.
  #
  #     cd examples/gallery
  #     BAGUETTE_HOST_FEATURES=playwright MIX_ENV=prod mix release --overwrite
  use ExUnit.Case, async: false
  alias Baguette.Playwright

  @moduletag :playwright

  @app Path.expand("../../examples/gallery/_build/prod/rel/gallery/bin/gallery_app", __DIR__)

  setup do
    app = Playwright.start_app!(@app, port: 9338)
    on_exit(fn -> Playwright.stop_app(app) end)
    %{page: Playwright.connect!(app), app: app}
  end

  test "gpui-kit components draw natively", %{page: page} do
    assert :ok = Playwright.await_text(page, "Failed")
    assert :ok = Playwright.await_text(page, "Done")
    assert Playwright.count(page, role: "progressbar", name: "Upload") == 1

    Playwright.click(page, "More")
    assert :ok = Playwright.await_text(page, "50% uploaded")
  end

  test "a long list asks Elixir for the rows it scrolls to", %{page: page} do
    assert :ok = Playwright.await_text(page, "Job 0")
    refute Playwright.visible?(page, text: "Job 77")

    # Rows are 32px tall: 75 rows down.
    Playwright.scroll(page, [text: "Job 1"], 0, 2400)
    assert :ok = Playwright.await_text(page, "Job 77")
    refute Playwright.visible?(page, text: "Job 0")
  end

  test "keymaps fire only with focus in their context", %{page: page} do
    assert :ok = Playwright.await_text(page, "Palette closed")
    Playwright.press(page, "Control+k")
    refute Playwright.visible?(page, text: "Palette open")

    Playwright.click(page, "Jobs panel")
    Playwright.press(page, "Control+k")
    assert :ok = Playwright.await_text(page, "Palette open")
    Playwright.press(page, "Escape")
    assert :ok = Playwright.await_text(page, "Palette closed")
  end

  test "Tab moves focus to the first tabindex", %{page: page} do
    assert :ok = Playwright.await_text(page, "Palette closed")
    Playwright.press(page, "Tab")
    Playwright.press(page, "Control+k")
    assert :ok = Playwright.await_text(page, "Palette open")
  end

  test "platform calls: clipboard, window title, a second window", %{page: page} do
    assert :ok = Playwright.await_text(page, "Appearance: light")

    Playwright.click(page, "Copy")
    Playwright.click(page, "Paste")
    assert :ok = Playwright.await_text(page, "Pasted: copied from gallery")

    Playwright.click(page, "Rename")
    assert :ok = Playwright.await_text(page, "Title: Gallery renamed")

    Playwright.click(page, "Details")
    assert :ok = Playwright.await_text(page, "Details open")
  end

  test "a canvas paints its shapes; pulse animates", %{page: page} do
    assert :ok = Playwright.await_text(page, "Palette closed")
    %{"x" => x, "y" => y} = Playwright.bounding_box(page, label: "Chart")
    shot = Playwright.screenshot(page)
    assert pixel(shot, x + 10, y + 10) == {255, 0, 0}
    assert pixel(shot, x + 96, y + 32) == {0, 255, 0}

    %{"x" => px, "y" => py, "width" => w} = Playwright.bounding_box(page, label: "Pulse")

    samples =
      for _ <- 1..4 do
        Process.sleep(200)
        pixel(Playwright.screenshot(page), px + w / 2, py + w / 2)
      end

    assert length(Enum.uniq(samples)) > 1
  end

  test "classes generated from Styled's methods apply (w-1/2)", %{page: page} do
    assert :ok = Playwright.await_text(page, "Palette closed")
    %{"width" => track} = Playwright.bounding_box(page, label: "Track")
    %{"width" => half} = Playwright.bounding_box(page, label: "Half")
    assert track == 256
    assert half == track / 2
  end

  test "animations tween any style, and are keyed by id", %{page: page} do
    assert :ok = Playwright.await_text(page, "Entry 1")
    Process.sleep(2_500)
    shot = Playwright.screenshot(page)
    # animate-to: the tween from red has ended blue.
    %{"x" => tx, "y" => ty} = Playwright.bounding_box(page, label: "Tween")
    assert pixel(shot, tx + 4, ty + 4) == {0, 0, 255}
    # The flash over Entry 1 has run out, and holds the end.
    %{"x" => x, "y" => y, "width" => w} = Playwright.bounding_box(page, label: "Entry 1")
    corner = {x + w - 4, y + 4}
    assert pixel(shot, elem(corner, 0), elem(corner, 1)) == {255, 255, 255}

    # A new entry takes the top row's place: its own id starts its own flash,
    # while Entry 1, now one row down, doesn't flash again.
    Playwright.click(page, "Add entry")
    assert :ok = Playwright.await_text(page, "Entry 2")
    shot = Playwright.screenshot(page)
    {r, g, b} = pixel(shot, elem(corner, 0), elem(corner, 1))
    assert g > 200 and r < 200 and b < 200, "the new entry isn't flashing: #{inspect({r, g, b})}"
    %{"x" => x1, "y" => y1, "width" => w1} = Playwright.bounding_box(page, label: "Entry 1")
    assert pixel(shot, x1 + w1 - 4, y1 + 4) == {255, 255, 255}
  end

  # The colour at `x`, `y` of a PNG, through ImageMagick.
  defp pixel(png, x, y) do
    path = Path.join(System.tmp_dir!(), "gallery-#{System.unique_integer([:positive])}.png")
    File.write!(path, png)
    at = "p{#{round(x)},#{round(y)}}"

    {out, 0} =
      System.cmd("convert", [
        path,
        "-format",
        "%[fx:int(255*#{at}.r)],%[fx:int(255*#{at}.g)],%[fx:int(255*#{at}.b)]",
        "info:"
      ])

    File.rm(path)
    out |> String.split(",") |> Enum.map(&String.to_integer(String.trim(&1))) |> List.to_tuple()
  end
end
