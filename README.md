# Baguette

Native [GPUI](https://www.gpui.rs) applications written in Elixir, on macOS,
Windows, Linux, Android and iOS.

Elixir owns application state, views, styling and tests. GPUI is only the
renderer. Screens are plain `Baguette.View`s or real Phoenix LiveViews using
the same HEEx templates, function components and `phx-*` bindings, and a
`<webview>` can host a web LiveView inside a native layout. Apps write Rust
only for platform-specific NIFs.

> **Status:** proof of concept, milestone 1 (repository skeleton). Nothing
> here is usable yet.

## How it fits together

- `native/baguette_host`: the native host, built on
  [`tauri-plugin-gpui`](https://github.com/ziinc/tauri-gpui). It owns the main
  thread on every platform, which macOS, iOS and Android require, and will
  embed the BEAM and load Baguette's NIF statically.
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

# Linux: install the Tauri prerequisites and a Vulkan driver first
cd native/baguette_host && cargo run
```

## License

MIT
