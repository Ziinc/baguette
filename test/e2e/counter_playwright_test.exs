defmodule Baguette.E2E.CounterPlaywrightTest do
  # The counter release built with the host's `playwright` feature, driven
  # through gpui-playwright. Build it first:
  #
  #     cd examples/counter
  #     BAGUETTE_HOST_FEATURES=playwright MIX_ENV=prod mix release --overwrite
  #
  # then run `mix test --only playwright` under a display (or headless).
  use ExUnit.Case, async: false
  alias Baguette.Playwright

  @moduletag :playwright

  @app Path.expand("../../examples/counter/_build/prod/rel/counter/bin/counter_app", __DIR__)

  setup do
    app = Playwright.start_app!(@app, port: 9334)
    on_exit(fn -> Playwright.stop_app(app) end)
    %{page: Playwright.connect!(app), app: app}
  end

  test "clicks reach the GenServer and the count re-renders", %{page: page} do
    assert :ok = Playwright.await_text(page, "Count: 0")

    Playwright.click(page, "Increment")
    Playwright.click(page, "Increment")
    Playwright.click(page, "Decrement")

    assert :ok = Playwright.await_text(page, "Count: 1")
  end

  test "buttons/1 names every button; aria_snapshot/1 is the whole window", %{page: page} do
    assert :ok = Playwright.await_text(page, "Count: 0")
    assert Enum.sort(Playwright.buttons(page)) == ["Decrement", "Increment"]
    assert Playwright.aria_snapshot(page) =~ ~s(button "Increment")
  end

  test "log/1 returns what the app has printed so far", %{app: app, page: page} do
    assert :ok = Playwright.await_text(page, "Count: 0")
    assert Playwright.log(app) =~ "baguette: playwright on"
  end
end
