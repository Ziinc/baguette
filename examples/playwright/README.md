# Tally: a Baguette app driven by Playwright

A small voting app, tested two ways:

- `test/tally_test.exs` runs the view headless with `Baguette.Test`.
- `test/playwright_test.exs` drives the real app with
  [playwright_ex](https://hex.pm/packages/playwright_ex), Playwright's Elixir
  client. Playwright's own locators, actions and auto-waiting assertions run
  against the native window, just as they would against a browser page.

The release turns on the host's `playwright` feature
(`baguette: [host_features: ["playwright"]]` in `mix.exs`). That embeds
[gpui-playwright](https://github.com/Ziinc/gpui-playwright), a Playwright
server inside the app. It only listens when `GPUI_PLAYWRIGHT` is set. Elements
are found by the view tree's roles, `aria-label`s and text:

```elixir
{:ok, _} = PlaywrightEx.Supervisor.start_link(ws_endpoint: "ws://127.0.0.1:9333/")
{:ok, browser} = PlaywrightEx.launch_browser(:chromium, timeout: 10_000)
{:ok, context} = PlaywrightEx.Browser.new_context(browser.guid, timeout: 10_000)
{:ok, page} = PlaywrightEx.BrowserContext.new_page(context.guid, timeout: 10_000)

PlaywrightEx.Frame.click(page.main_frame.guid,
  selector: PlaywrightEx.Selector.button("Vote for Elixir"),
  timeout: 10_000
)
```

Run it from the repository root (it needs a display, and starts Xvfb when
there isn't one):

```sh
scripts/e2e-playwright.sh
```

That builds the release and runs `mix test --only playwright`. The test starts
`_build/prod/rel/tally/bin/tally_app` with `GPUI_PLAYWRIGHT=9333` and connects
to it.
