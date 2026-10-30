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
end
