# Baguette

Native [GPUI](https://www.gpui.rs) applications written in Elixir, on macOS,
Windows, Linux, Android and iOS.

Elixir owns application state, views, styling and tests. GPUI is only the
renderer. Screens are plain `Baguette.View`s or real Phoenix LiveViews using
the same HEEx templates, function components and `phx-*` bindings, and a
`<webview>` can host a web LiveView inside a native layout. Apps write Rust
only for platform-specific NIFs.

> **Status:** proof of concept. Linux desktop works end to end; Android,
> LiveView and the other platforms are in progress.

![A Broadway pipeline visualised live](docs/firehose.gif)

## Examples

| | |
| --- | --- |
| [`examples/broadway`](examples/broadway) | A Broadway pipeline (producer, four processors, two batchers) drawn live: rates, load, batches, acks, failures and back-pressure. |
| [`examples/counter`](examples/counter) | The smallest app: a count held in a GenServer. |
| [`examples/board`](examples/board) | A card dragged around a board (`phx-drag`, `absolute`, `<line>`). |
| [`examples/todo`](examples/todo) | A to-do list: a form with a native text input, checkboxes, list roles. |

Each one is a `mix release`:

```sh
cd examples/broadway
MIX_ENV=prod mix release
_build/prod/rel/firehose/bin/firehose_app
```

The host links a prebuilt BEAM (`liberlang.a`) for your OTP version, which
`mix release` downloads and checks against a pinned SHA-256. To use your own,
build it with `scripts/build-liberlang.sh OTP-29.1.2 ~/liberlang` and set
`BAGUETTE_LIBERLANG=~/liberlang`.

## A view

```elixir
defmodule Counter.View do
  use Baguette.View

  def mount(_args), do: {:ok, %{count: Counter.Store.get()}}

  def render(assigns) do
    ~H"""
    <div class="size-full flex-col items-center justify-center gap-6 bg-background">
      <text class="text-3xl font-bold">Count: {@count}</text>
      <button class="px-4 py-2 rounded-md bg-primary hover:opacity-90" phx-click="inc"
        aria-label="Increment">+</button>
    </div>
    """
  end

  def handle_event("inc", _values, assigns), do: {:noreply, %{assigns | count: Counter.Store.inc()}}
end
```

And its test, headless:

```elixir
test "increments" do
  Baguette.Test.click(0, "Increment")
  assert Baguette.Test.text(0) =~ "Count: 1"
end
```

## Elements and events

Templates use HTML's vocabulary where GPUI can draw it:

| Write | Get |
| --- | --- |
| `<div>`, `<text>`, `<button>` and Tailwind-style classes | flex layout, colours (theme tokens, `[#hex]`, `token/12` alpha), spacing, `max-w-*`/`min-h-*`, `relative`/`absolute` with `left-[Npx]`, `top-*`, `overflow-y-scroll`, `hover:`/`active:`/`disabled:` |
| `<input name value placeholder>` (`type="password"` masks) | a native text input (gpui-kit's) |
| `<input type="checkbox" checked>` | a native checkbox |
| `<form phx-submit phx-change>` | Enter in an input, or a `<button type="submit">`, submits it |
| `<line x1 y1 x2 y2 class="stroke-…">`, `curve` | a straight line, or an S-curve, in the parent's coordinates |
| `<ul>`/`<li>`, `<h1>`–`<h6>`, `<a>`, `<nav>`, `<main>`, …, or `role="…"`, `aria-label`, `aria-checked` | the accessibility role and name screen readers and tests find |

Events arrive in `handle_event(event, values, assigns)`, shaped as in Phoenix:

| Binding | Values |
| --- | --- |
| `phx-click` | the element's `phx-value-*`; a checkbox adds `"checked"` (its new state) |
| `phx-drag` | `phx-value-*` plus `"dx"`, `"dy"`: how far it was dragged, sent on release |
| `phx-change` on an input or its form | the form's named values (or `%{name => text}`), plus `"_target"` |
| `phx-submit` on a form | every named value in the form; checked checkboxes are `"on"` |

The theme's tokens also style the native inputs and checkboxes (gpui-kit's
theme): `primary`, `primary-foreground`, `ring`, `border`, `input`,
`background`, `foreground`, `muted`, `muted-foreground`, `accent`, `link`,
`success`, `warning`, `danger`.

Typed text stands until the view renders a different `value`, so to clear an
input after submitting, track it with `phx-change` and reset it.

## Testing

`Baguette.Test` drives views headlessly with the same events the host sends:
`click/2`, `drag/4`, `fill/3`, `submit/2`, `value/2`, `text/1`, `tree/1`.

`Baguette.Playwright` drives a real release through
[gpui-playwright](https://github.com/ziinc/gpui-playwright), from ExUnit
(optional deps `playwright_ex` and `websockex`). Build with
`BAGUETTE_HOST_FEATURES=playwright mix release`, then under a display
(`xvfb-run -a` on Linux):

```elixir
app = Baguette.Playwright.start_app!("_build/prod/rel/todo/bin/todo_app")
on_exit(fn -> Baguette.Playwright.stop_app(app) end)
page = Baguette.Playwright.connect!(app)

Baguette.Playwright.fill(page, "Title", "Buy milk")
Baguette.Playwright.press(page, "Title", "Enter")
Baguette.Playwright.check(page, "Buy milk")
assert Baguette.Playwright.count(page, role: "listitem") == 1
assert :ok = Baguette.Playwright.await_text(page, "0 of 1 left")
```

Actions: `click`, `scroll`, `fill`, `clear`, `press`, `type`, `check`, `uncheck`,
`focus`, `hover`, `drag`, `resize`. Reads: `input_value`, `checked?`,
`visible?`, `enabled?`, `text_content`, `attribute`, `count`,
`bounding_box`, `aria_snapshot`, `buttons`, `screenshot`. Waits:
`await_text`, `await`. App: `start_app!` (any free port, found through the
endpoint file), `stop_app`, `log`, `alive?`. A string target names the role
the action implies (a button to click, a textbox to fill); a keyword list
(`role:`, `name:`, `text:`, `label:`, `placeholder:`, `test_id:`, `nth:`,
`exact:`) builds any locator.

## How it fits together

- `native/baguette_host`: the native host, built on
  [`tauri-plugin-gpui`](https://github.com/ziinc/tauri-gpui). It owns the main
  thread on every platform, which macOS, iOS and Android require. It links
  the BEAM (`liberlang.a`), boots the app's release with `erl_start`, and
  draws the trees the release sends.
- `native/baguette_nif`: the Rustler NIF that connects `Baguette.Host` to the
  host's C ABI (`native/baguette_abi`).
- `lib/`: the Elixir library: views, the render protocol, components, test
  helpers and `mix release` packaging.

GPUI is pinned to `gpui-pre =0.3.9`, the snapshot
[gpui-kit](https://crates.io/crates/gpui-kit) 0.7.3,
gpui-testing-library and gpui-visual-test use.

## Roadmap

1. Skeleton: Mix project, Rust host crate, Linux CI.
2. Embedded BEAM: the host boots a `mix release` and loads a static NIF.
3. Render layer: primitives, Tailwind-style classes, state variants.
4. Acceptance gate: a counter on Android whose state lives in a GenServer.
5. LiveView in a `<webview>` on desktop.
6. LiveView in a `<webview>` on Android.
7. Elixir starter components and a todo list.
8. ExUnit testing: render trees, headless interaction, screenshots.
9. Platform NIF extension point.
10. iOS, including the webview.
11. Hardening and a CI matrix for all five targets.

## Development

```sh
mix test
(cd native && cargo test)
scripts/e2e-linux.sh   # the counter release, clicked through AT-SPI on Xvfb
```

End-to-end tests through [gpui-playwright](https://github.com/ziinc/gpui-playwright),
written in ExUnit with `Baguette.Playwright`:

```sh
(cd examples/counter && BAGUETTE_HOST_FEATURES=playwright MIX_ENV=prod mix release --overwrite)
mix test --only playwright
```

## Releasing

Pushing a `v*` tag runs CI and publishes the Firehose builds as a GitHub
release: `.deb` and AppImage, `.dmg` for Apple silicon and Intel, and a
signed Android APK and AAB. Signing comes from repository secrets:

- Android: `ANDROID_KEYSTORE` (the keystore, base64), `ANDROID_KEYSTORE_PASSWORD`,
  `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Without them the build is signed
  with a throwaway key, which Google Play rejects.
- macOS: Tauri's `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`,
  `APPLE_SIGNING_IDENTITY`, and `APPLE_ID`, `APPLE_PASSWORD`, `APPLE_TEAM_ID`
  to notarize. Without them the app is unsigned.

The prebuilt BEAMs come from the `liberlang` workflow, which publishes
`liberlang-OTP-<version>` once per OTP version; pin the checksums from its
summary in `priv/liberlang.sha256`.

## License

MIT
