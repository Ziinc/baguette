# Native API: GPUI and gpui-kit for Elixir

How Baguette exposes GPUI and gpui-kit to Elixir, and which part of them it
promises to keep stable.

GPUI renders every frame on the main thread, so Elixir never runs inside a
frame. Elixir describes the UI as data and the host carries it out each
frame. Elixir calls into GPUI directly only for app, window and platform work.
Anything that needs per-frame logic is a Rust component, registered with the
host.

## Layers

| Layer | What Elixir writes | Lives in |
| --- | --- | --- |
| 1. Elements and style | HEEx tags and attributes | `view.rs`, `style.rs` |
| 2. Input and focus | `phx-*` bindings, keymaps | `view.rs` |
| 3. App, window, platform | `Baguette.*` function calls | NIF, then host |
| 4. Native components | `<.name>` from a component set | `components.rs` plus sets |

## The stable set

Baguette binds only GPUI APIs that came through the 2024–2025 rewrites with
the same names and meaning. Its Elixir API is promised across `gpui-pre`
bumps. A bump may change the Rust behind it, but never the HEEx.

**Elements**
- `div`, text and styled text runs, `img`, `svg`
- `uniform_list` and `list`: virtualized rows
- `canvas`: paint callbacks
- `anchored` and `deferred`: popovers and overlays
- `with_animation`

**Style**
- The `Styled` methods: flex, grid, size, spacing, position, overflow,
  border, radius, background, shadow, opacity, cursor and text.
- Today these are reached through classes (`style.rs`). Generating them from
  rustdoc JSON is a later step, and stays limited to this list.

**Interaction**
- Click, mouse down/up/move, scroll wheel, drag and drop, hover/active
  styles, tooltip.
- `track_focus` with focus handles, `key_context`, `on_action`.
- `KeyBinding` with `bind_keys`.

**App, window, platform**
- Open and close windows; title and bounds.
- Clipboard read and write, `open_url`, `prompt_for_paths`, save dialogs,
  `set_menus`.
- Window appearance (light or dark) and displays.

**gpui-kit**
- `base` controls: focus, keyboard activation, accessibility.
- `Root`: dialogs and popovers.
- Theme and the text input.

**Left out on purpose**
- The `Element` trait's layout, prepaint and paint internals.
- Entity and context plumbing.
- Text-system internals.
- `Role` and other accessibility types that are new in the fork.
- `canvas` is the one way in to painting.

## Native components (layer 4)

A component set is a `&'static [Component]` in Rust. Each component gives a
tag, its attributes and their types, its events, whether it takes children,
and a render function that takes `Props`. The host:

- looks a tag up in `components::sets()` before its built-in elements (see
  `view.rs`);
- prints every registered component with `baguette_host --manifest`.

Elixir generates checked function components from that manifest:

```elixir
defmodule MyApp.Kit do
  use Baguette.Components, manifest: "../priv/components/kit.json", prefix: "kit-"
end
```

`test/fixtures/components.json` is the manifest format. The Rust and Elixir
tests both read it, so the two sides can't drift apart.

## In place

- `components.rs`: `Component`, `Attr`, `AttrType`, `Props`, `Set`,
  `sets()`, `find/1`, `manifest/1` and `manifest_of/1`, with unit tests.
- The renderer dispatches registered tags.
- `baguette_host --manifest [set]`.
- `Baguette.Components`: one function component per manifest entry, with
  `attr` and `slot` declarations, `@doc`, a `__manifest__/0` function, and
  recompilation when the manifest changes.
- **Component sets** (step 1). Each set is a `components-<set>` Cargo
  feature of `baguette_host`. gpui-kit's (`components/gpui_kit.rs`, on by
  default) has `kit-tag`, `kit-progress`, `kit-spinner`, `kit-skeleton` and
  `kit-kbd`; Elixir imports them from `Baguette.Kit`.
  - A release chooses its sets with `baguette: [components: ["gpui-kit"]]`;
    `[]` leaves them all out.
  - `mix baguette.components` writes each set's manifest into
    `priv/components/<set>.json`. A Rust test fails when the committed
    manifest no longer matches the set.
  - `examples/gallery` shows them, and its end-to-end test draws them.
- **Manifest checks** (step 2). A manifest names its set and records the
  `gpui-pre` and gpui-kit versions from `Cargo.lock` and an FNV-1a hash of
  it all. Each `Baguette.Components` module has `__set__/0`, and
  `Baguette.Components.compiled/0` collects them. The NIF's `attach` passes
  them to the host (`check_components`, ABI 2), which refuses a set whose
  hash differs: it says so in the window, ignores renders and `attach`
  returns `{:error, :components_mismatch}`. Sets the host lacks are only
  logged.
- **Long lists** (step 3). `<list id="jobs" rows={@count} phx-rows="jobs">`
  is a `uniform_list` (`list.rs`). The host draws the rows on screen and asks
  for the ones it lacks with a `rows` event: the rows to send plus the range
  on screen with a screen's margin either side. `Baguette.View` calls
  `handle_rows(event, range, assigns)`, which returns
  `{:reply, rows, assigns}`, and sends the rows. Every render of the view
  renders each list's on-screen range again and sends it with the frame,
  where it replaces the host's cache, so rows follow the assigns like the
  rest of the template. Rows are `row-height` px tall (default 24) until
  they arrive; GPUI then measures them from the first row the host has.
  `Baguette.Test.show_rows/3` scrolls headlessly.
- **Tree patches** (step 4). After a window's first frame, `Baguette.Host`
  sends `Baguette.Patch.diff/2` of the last frame and the new one:
  `replace`, `attrs` and `splice` operations addressed by child-index path,
  with equal leading and trailing children kept and a changed `id` treated
  as a new element. `patch.rs` applies them. A patch that doesn't fit makes
  the host send `resync`, and gets the whole frame. A new theme sends the
  whole frame too. `test/fixtures/patches.json` holds the cases both sides
  are tested against.
- **Keymaps and focus** (step 5). `keymap "secondary-k", :open_palette,
  context: "Jobs"` in a `Baguette.View` declares a binding; full frames
  carry the keymap and the host binds each new one once with `KeyBinding`
  and `bind_keys` (`keymap.rs`), as a single `ElixirAction` type carrying
  the action's name. A global `on_action` listener sends it back, and the
  view calls `handle_action(action, assigns)`. `key-context="Jobs"` on an
  element is its `key_context`; `tabindex="N"` gives it a focus handle with
  that tab index (`track_focus`), so a click focuses it and gpui-kit's Tab
  and Shift-Tab follow the order. The window's content holds focus when
  nothing in it does, as a browser's body does, so Tab and context-free
  bindings work before anything is clicked. `Baguette.Test.keystroke/3` and
  `focus_order/1` drive it headlessly.
- **Platform calls** (step 6). `Baguette.Clipboard` (`read/0`, `write/1`),
  `Baguette.Window` (`open/2`, `close/1`, `set_title/2`, `set_bounds/2`,
  `info/1`), `Baguette.Menu.set/1` and `Baguette.App` (`open_url/1`,
  `appearance/0`) go through `Baguette.Host.call/2`. ABI 3 adds `call`.
  The host runs each call on its UI thread (`platform.rs`) and replies with
  a `reply` event carrying the call's ref. GPUI does the clipboard and the
  appearance. Tauri, the platform under GPUI here, does windows, menus and
  URLs: tauri-gpui's platform leaves `set_menus`, `open_url` and the path
  prompts to Tauri plugins. `windows.rs` keeps each window's root, and
  queues renders for windows that aren't open yet. A menu click is an event
  to window 0's view. An appearance change is
  `handle_info({:appearance, :dark}, assigns)`. Without a native host, the
  calls change a headless platform that `Baguette.Host.platform/0` reads.
- **Canvas paint commands and animation** (step 7). A `<canvas>`'s
  children are shapes in pixels from its top left: `rect` (`rx`), `circle`,
  `line`, `polyline`, `polygon` and `path` (absolute `M L H V C Q Z`),
  coloured by `fill-<color>` and `stroke-<color>` with `stroke-width`.
  `paint.rs` reads them and paints them with `gpui::canvas`, using
  `paint_quad` and `PathBuilder`. The gallery's e2e test checks the
  painted pixels.
- **Animations** (`animation.rs`). Any element tweens its style from
  `animate-from` to `animate-to` (classes; either defaults to its own
  `class`). Every numeric and colour property GPUI's style holds
  interpolates: opacity, background, text and border colours, font size,
  sizes, insets, margins, padding, gaps, radii and border widths.
  - Timing: `duration` and `delay` (ms), `easing` (GPUI's `linear`,
    `quadratic`/`ease-in`, `ease-in-out`, `ease-out`, `bounce`, `pulsate`,
    or `cubic-bezier(...)`), `repeat` (a count or `infinite`), `direction`
    (`normal`, `reverse`, `alternate`, `alternate-reverse`) and `fill`
    (`forwards` by default, as GPUI's `with_animation` holds the end;
    `backwards`, `both`, `none`).
  - Presets: `animate="pulse|fade-in|fade-out|flash"`, which those
    attributes adjust. `<icon animate="spin">` turns with `with_animation`.
  - An animation starts when its element first renders, keyed by its `id`
    (else its path), so a prepended row keeps or starts its own; a new
    `id` starts a new one. The host asks for animation frames only while
    one runs, and the element keeps its layout and stays observable.
- **Generated style attributes** (step 8). `mix baguette.styles` reads
  `gpui-pre`'s rustdoc JSON (this needs nightly) and writes `style_gen.rs`.
  That file is a sorted table with one class per argument-free `Styled`
  method in the stable categories: about 3,100, such as `w-1/2`, `-mt-2`,
  `p-0.5`, `rounded-t-lg`, `gap-x-3` and `cursor-grab`. `style.rs` tries the
  table after its own classes, so the hand-written meanings win. The file
  is committed and builds use stable Rust. Run the task again after a
  GPUI bump.

## Precompiled host and NIF

`mix release` compiles no Rust for an app on the default host (gpui-kit's
component set, no `host_features`):

- `Baguette.Release.host_source/2` picks the host: `BAGUETTE_HOST_BINARY`, or
  the precompiled `baguette_host-v<vsn>-OTP-<otp>-<target>.tar.gz` from
  the version's GitHub release (`host.yml`), checked against
  `priv/host.sha256`. It is built with the `dist` profile (fat LTO,
  `opt-level = "s"`): 33 MB on Linux instead of the 107 MB of a plain
  release build. Another component set, any host feature (such as
  `playwright`), `BAGUETTE_BUILD_HOST=1`, or a version without pinned
  checksums builds it with Cargo.
- `bundle/1` runs `tauri bundle` on the installed host, so bundling
  compiles nothing either. The host finds the release by its own path
  (`/usr/lib/<name>/release`, `Contents/Resources/release`), since a
  precompiled binary doesn't know its app's name.
- The NIF is precompiled with rustler_precompiled (`nif.yml`).

## Next, in order

Each step is test first: Rust unit tests, Baguette.Test, then one
gpui-playwright end-to-end test.

1. **Component sets behind Cargo features.**
   - A `gpui-kit` set first (it's already a dependency). gpui-bootstrap's
     set comes later, as an optional crate.
   - A release option chooses the sets: `baguette: [components: [...]]`.
   - A mix task writes the manifests into `priv/components/`.
2. **Manifest checks.**
   - The manifest records `gpui-pre` and gpui-kit versions plus a hash.
   - The host compares the hash when the NIF attaches and refuses a
     mismatch.
3. **Long lists.**
   - `<list rows={n} phx-rows="rows">` backed by `uniform_list`.
   - The host asks for rows by range, Elixir answers with
     `handle_rows(range, assigns)`, and the host caches the answers.
   - Crawlaway's live data stream needs this.
4. **Tree patches.**
   - Send what changed, keyed by element id and path, instead of the whole
     tree every render.
5. **Keymaps and focus.**
   - `keymap "cmd-k", :open_palette, context: "Jobs"` with `handle_action/2`.
   - Focus order.
6. **Platform calls.**
   - `Baguette.Clipboard`, `Baguette.Window`, `Baguette.Menu`,
     `Baguette.App.open_url/1` and appearance events.
   - Calls go over the NIF's ABI, so they need an `ABI_VERSION` bump.
7. **Canvas paint commands and animation.**
8. **Generated style attributes.**
   - Use rustdoc JSON of `Styled`, limited to the stable list above.
