# Baguette

Native [GPUI](https://www.gpui.rs) applications written in Elixir.

Elixir owns application state, views, styling and tests. GPUI is only the
renderer. Screens are `Baguette.View`s written in HEEx, with function
components and Phoenix's `phx-*` bindings. Apps write Rust only for
platform-specific NIFs.

> **Status:** early. Linux desktop works end to end and macOS is built and
> booted in CI. Android builds its host from source; Windows and iOS are not
> supported yet.

![A Broadway pipeline visualised live](docs/firehose.gif)

## Examples

| | |
| --- | --- |
| [`examples/broadway`](examples/broadway) | A Broadway pipeline (producer, four processors, two batchers) drawn live: rates, load, batches, acks, failures and back-pressure. |
| [`examples/counter`](examples/counter) | The smallest app: a count held in a GenServer. |
| [`examples/board`](examples/board) | A card dragged around a board (`phx-drag`, `absolute`, `<line>`). |
| [`examples/todo`](examples/todo) | A to-do list: a form with a native text input, checkboxes, list roles. |
| [`examples/gallery`](examples/gallery) | The native API: gpui-kit components, canvas painting, animations, long lists. |

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

### Smaller releases

`package/1` trims every release to what it runs:

- **Code:** it removes the modules nothing in the release can reach,
  Elixir's, IEx's and the dependencies' included. `kernel`, `stdlib`,
  `logger`, `telemetry` and the OTP apps that dispatch on computed names
  (`crypto`, `ssl`, `public_key`, `inets`, `asn1`) stay whole. Keep anything
  it can't see, such as a module reached by `Module.concat/1` or a debugging
  tool like `recon`, with
  `baguette: [keep: [modules: [MyDep.Plugin], apps: [:recon]]]`.
- **ERTS:** the host links the BEAM, so it keeps only `erl_child_setup` and
  `inet_gethost`. Start the app with `bin/<name>_app`; `bin/<name>` can no
  longer start the release.
- **Files:** `lib/*/src`, `lib/*/include` and `lib/*/doc`, plus the globs in
  `prune:`.

`releases/<vsn>/slim.json` lists what went and why (`Baguette.Release.Slim`).
To catch a module the release reaches only by a computed name, call
`Baguette.Release.Slim.Check.start()` in `test_helper.exs`: it fails the
suite when the tests load a module the release would purge.

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
| `<div>`, `<text>`, `<button>` and Tailwind-style classes | flex layout, colours (theme tokens, `[#hex]`, `token/12` alpha), spacing, `max-w-*`/`min-h-*`, `relative`/`absolute` with `left-[Npx]`, `top-*`, `overflow-(x-|y-)scroll` or `-auto` (wheel and touch scrolling), `hover:`/`active:`/`disabled:` |
| `<input name value placeholder>` (`type="password"` masks) | a native text input (gpui-kit's) |
| `<input type="checkbox" checked>` | a native checkbox |
| `<form phx-submit phx-change>` | Enter in an input, or a `<button type="submit">`, submits it |
| `<button phx-pick-file accept="csv,xlsx">`, `<button phx-pick-save default-name="out.csv">` | a native open or save dialog (desktop) |
| `<line x1 y1 x2 y2 class="stroke-…">`, `curve` | a straight line, or an S-curve, in the parent's coordinates |
| `<icon name="undo-2" class="size-4 text-primary" />` | a [lucide](https://lucide.dev/icons) icon from gpui-kit's catalog, by kebab-case name: 16px unless sized, in its `text-*` colour or else the inherited one. An unknown name draws nothing in the same space and logs `baguette: unknown icon` once |
| `title="Undo (Ctrl+Z)"` on any element | a tooltip on hover |
| `<ul>`/`<li>`, `<h1>`–`<h6>`, `<a>`, `<nav>`, `<main>`, …, or `role="…"`, `aria-label`, `aria-checked` | the accessibility role and name screen readers and tests find |

Events arrive in `handle_event(event, values, assigns)`, shaped as in Phoenix:

| Binding | Values |
| --- | --- |
| `phx-click` | the element's `phx-value-*`; a checkbox adds `"checked"` (its new state) |
| `phx-drag` | `phx-value-*` plus `"dx"`, `"dy"`: how far it was dragged, sent on release |
| `phx-change` on an input or its form | the form's named values (or `%{name => text}`), plus `"_target"` |
| `phx-submit` on a form | every named value in the form; checked checkboxes are `"on"` |
| `phx-pick-file`, `phx-pick-save` | `phx-value-*` plus `"path"`, the chosen file; nothing on cancel |
| `phx-window-keydown`, optionally `phx-key="Escape"` | `phx-value-*` plus `"key"` and the booleans `"ctrl"`, `"shift"`, `"alt"`, `"meta"`, for every keystroke the window hears (only `phx-key`'s, ignoring case) |

Window keys are named as the browser's `KeyboardEvent.key` names them
(`"Enter"`, `"Escape"`, `"ArrowUp"`, `" "`, `"F5"`, `"="`), except that
letters stay lowercase with Shift: Ctrl+Shift+Z is
`%{"key" => "z", "ctrl" => true, "shift" => true}`. Modifiers are reported
as pressed and never merged: `"meta"` is Cmd on macOS (Super or the Windows
key elsewhere), so a cross-platform shortcut checks `ctrl or meta`. While a
text input has focus, typing fires nothing: only chords with Ctrl or Meta
reach the window, and not the ones the input handles itself (its own undo,
redo, select all, copy, cut and paste on Ctrl/Cmd + Z, Y, A, C, X, V; Enter
submits its form).

The theme's tokens also style the native inputs and checkboxes (gpui-kit's
theme): `primary`, `primary-foreground`, `ring`, `border`, `input`,
`background`, `foreground`, `muted`, `muted-foreground`, `accent`, `link`,
`success`, `warning`, `danger`.

Typed text stands until the view renders a different `value`, so to clear an
input after submitting, track it with `phx-change` and reset it.

## Testing

`Baguette.Test` drives views headlessly with the same events the host sends:
`click/2`, `drag/4`, `fill/3`, `submit/2`, `pick_file/3`,
`keydown/4` (`keydown(0, "z", [:ctrl], focus: "Title")`), `value/2`,
`text/1`, `icons/2` (the `<icon>` names drawn, in the element labelled),
`tree/1`. End-to-end, `BAGUETTE_PICK_FILE=/path` makes every
native file picker answer with that path instead of opening a dialog.

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

Actions: `click`, `scroll`, `fill`, `clear`, `press` (in a target, or
`press(page, "Control+z")` on the window), `type`, `check`, `uncheck`,
`focus`, `hover`, `drag`, `resize`. Reads: `input_value`, `checked?`,
`visible?`, `enabled?`, `text_content`, `attribute`, `count`,
`bounding_box`, `aria_snapshot`, `buttons`, `screenshot`. Waits:
`await_text`, `await`. App: `start_app!` (any free port, found through the
endpoint file), `stop_app`, `log`, `alive?`. A string target names the role
the action implies (a button to click, a textbox to fill); a keyword list
(`role:`, `name:`, `text:`, `label:`, `placeholder:`, `test_id:`, `nth:`,
`exact:`) builds any locator.

The host serves Playwright's own protocol, so
[playwright_ex](https://hex.pm/packages/playwright_ex) can drive it
directly too: the app is the browser and its window the page.

```elixir
{:ok, _} = PlaywrightEx.Supervisor.start_link(ws_endpoint: "ws://127.0.0.1:9333/")
{:ok, browser} = PlaywrightEx.launch_browser(:chromium, timeout: 10_000)
{:ok, context} = PlaywrightEx.Browser.new_context(browser.guid, timeout: 10_000)
{:ok, page} = PlaywrightEx.BrowserContext.new_page(context.guid, timeout: 10_000)

PlaywrightEx.Frame.click(page.main_frame.guid,
  selector: PlaywrightEx.Selector.button("Increment"),
  timeout: 10_000
)
```

Start the release with `GPUI_PLAYWRIGHT=9333` for that; the server only
listens when it is set.

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

[`docs/native-api.md`](docs/native-api.md) has what is exposed of GPUI and
gpui-kit, and the plan for the rest:

1. `img`, `anchored`/`deferred` and text styles.
2. Hover, key, scroll and focus events, and real drag and drop.
3. Window controls and displays.
4. gpui-kit components: dialog, popover, select, tabs, table, switch, ….

Platforms: a precompiled Android host, then Windows and iOS.

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

The release also carries what apps download instead of compiling Rust:

- Baguette's NIF, for macOS (Apple silicon, Intel), Linux (x86_64, arm64)
  and Windows (`nif` workflow).
- The default host (gpui-kit's components, no host features), for macOS and
  Linux on each OTP version (`host` workflow). A release with other
  components or features, `BAGUETTE_BUILD_HOST=1`, or a version without
  pinned checksums builds it with Cargo.

After the tag's release is published, pin both sets of checksums, which the
hex package ships, then publish:

```sh
# priv/host.sha256: the lines from the host workflow's summary
mix rustler_precompiled.download Baguette.Native --all --print
mix hex.publish
```

Checkouts and git dependencies have no NIF checksums and build the NIF from
source, as does setting `BAGUETTE_BUILD_NIF=1`.

The prebuilt BEAMs come from the `liberlang` workflow, which publishes
`liberlang-OTP-<version>` once per OTP version; pin the checksums from its
summary in `priv/liberlang.sha256`.

## License

MIT
