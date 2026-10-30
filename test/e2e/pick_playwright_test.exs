defmodule Baguette.E2E.PickPlaywrightTest do
  # The board release with BAGUETTE_PICK_FILE, the host's test hook that
  # answers file pickers without opening the native dialog.
  use ExUnit.Case, async: false
  alias Baguette.Playwright

  @moduletag :playwright

  @app Path.expand("../../examples/board/_build/prod/rel/board/bin/board_app", __DIR__)

  setup do
    app = Playwright.start_app!(@app, env: [{"BAGUETTE_PICK_FILE", "/tmp/orders.csv"}])
    on_exit(fn -> Playwright.stop_app(app) end)
    %{page: Playwright.connect!(app), app: app}
  end

  test "a phx-pick-file button sends the chosen path with its values", %{page: page, app: app} do
    Playwright.click(page, "Choose file")
    assert :ok = Playwright.await_text(page, "Chose /tmp/orders.csv")
    assert Playwright.alive?(app)
    refute Playwright.log(app) =~ "panicked"
  end
end
