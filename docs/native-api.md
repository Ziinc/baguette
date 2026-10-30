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

## Scaffolding in place

- `components.rs`: `Component`, `Attr`, `AttrType`, `Props`, `Set`,
  `sets()` (empty), `find/1` and `manifest/1`, with unit tests.
- The renderer dispatches registered tags.
- `baguette_host --manifest`.
- `Baguette.Components`: one function component per manifest entry, with
  `attr` and `slot` declarations, `@doc`, a `__manifest__/0` function, and
  recompilation when the manifest changes.

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
