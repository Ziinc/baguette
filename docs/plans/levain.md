# Levain

Plan, as of 13 Nov 2026.

Levain is the shared Rust host of the Boulangerie project: one renderer, platform layer and C ABI that baguette (Elixir), chouquette (TS/JS) and briochette (Python) all run on. It is extracted from baguette's `native/` in M0, with baguette's tests passing unchanged. Docs: [boulangerie.tznc.dev](https://boulangerie.tznc.dev). Repos stay under Ziinc.

## Crates

Levain is a Cargo workspace of four crates. Each language builds a thin host binary on top of it.

| Crate | Kind | Contents |
| --- | --- | --- |
| `levain-abi` | lib | The C ABI (`HostApi`, `EventSink`), today's `baguette_abi`. No dependencies |
| `levain` | lib | Renderer, bridge, component sets, platform calls, app startup, mobile unpacking, the `playwright` feature, the `Runtime` trait |
| `levain-pack` | bin | Packaging: picks the precompiled host and checks its SHA-256, runs `tauri bundle`, generates the iOS and Android projects |
| `levain-build` | lib | Build-script helpers for host crates (pending confirmation) |

| Host | Built from | Lives in |
| --- | --- | --- |
| `baguette_host` | `levain` + the BEAM runtime (today's `beam.rs`, liberlang) | Ziinc/baguette |
| `chouquette_host` | `levain` + the QuickJS runtime; a second build with the libnode runtime | Ziinc/chouquette |
| `briochette_host` | `levain` + the CPython runtime | Ziinc/briochette |

Each host's `main.rs` is about 20 lines: `levain::run(runtime, tauri::generate_context!())`, with the host's own Tauri context. All three crate names were free on crates.io, and `levain` on Hex, on 13 Nov 2026.

## What moves out of baguette

About 8,500 of the 9,100 lines of Rust in `baguette/native` move to levain. Only BEAM startup and the NIF stay.

| baguette file | Moves to | What it does |
| --- | --- | --- |
| `baguette_abi/src/lib.rs` | `levain-abi` | C ABI: render, call, event sink, component check |
| `bridge.rs` | `levain::bridge` | Renders and calls to the UI thread; events back to the runtime |
| `view.rs`, `style.rs`, `style_gen.rs`, `patch.rs` | `levain::render` | Node tree to GPUI elements; Tailwind-style classes; patches |
| `list.rs`, `paint.rs`, `animation.rs`, `keymap.rs` | `levain::render` | Virtualized lists, canvas, animation, keymaps and focus |
| `components.rs`, `components/gpui_kit.rs` | `levain::components` | Native component sets, manifests, hash check |
| `platform.rs`, `windows.rs`, `pick.rs`, `portal.rs` | `levain::platform` | Windows, menus, clipboard, dialogs, open\_url, appearance |
| `lib.rs` `run()` | `levain::run` | Tauri builder, tauri-plugin-gpui init, window 0, error notice |
| Generic half of `beam::mobile` | `levain::mobile` | Unpacking the embedded app, Android logging |
| `baguette_ios` | `levain-ios` template | Static library Xcode links |
| Parts of `build.rs` | `levain` build helpers | Windows manifest workaround, embedding the app, recording versions |
| `playwright.rs` | `levain` (`playwright` feature) | gpui-playwright server |
| `test/fixtures/patches.json`, `components.json` | levain repo | Conformance fixtures; plus a new `events.json` |
| Host parts of `lib/baguette/release.ex` | `levain-pack` | Host selection, checksums, bundling, iOS/Android projects |

Stays in baguette: `beam.rs` (as the BEAM runtime crate), `baguette_nif`, and all of `lib/`.

## The Runtime trait

The one seam between levain and a language. A runtime finds its app and starts it on its own thread; from then on it talks to the host only through the C ABI.

```rust
pub trait Runtime: Send + 'static {
    /// The app next to the executable, in the bundle's resources,
    /// or unpacked from the host library on mobile.
    fn locate(&self, paths: &AppPaths) -> Result<App, String>;

    /// Starts the app on its own thread. It calls `api.render`,
    /// `api.call` and `api.set_event_sink`, never GPUI directly.
    fn start(&self, app: App, api: &'static levain_abi::HostApi) -> Result<(), String>;
}

// chouquette_host/src/main.rs
fn main() {
    levain::run(chouquette_quickjs::QuickJs::default(), tauri::generate_context!());
}
```

- `App` carries the app's root, name and `app.json` (window title and size, component sets), today's `baguette.json`.
- The ABI keeps today's layout; renaming its symbols bumps `ABI_VERSION` to 4.

## Distribution and platforms

Decided: **levain is Rust only.** App developers never install it; each language package bundles its prebuilt host and `levain-pack`.

| Registry | Package | Carries |
| --- | --- | --- |
| Git (crates.io later) | `levain`, `levain-abi`, `levain-pack` | Source, for the language repos |
| Hex | `baguette` | Downloads `baguette_host` + `levain-pack` from GitHub releases, SHA-256 checked |
| npm | `chouquette` + `@chouquette/host-<platform>` | `chouquette_host` (QuickJS and Node builds) + `levain-pack` |
| PyPI | `briochette` (per-platform wheels) | `briochette_host` + `levain-pack` |

- crates.io rejects git dependencies, and levain inherits three: tauri-plugin-gpui, gpui-playwright and the patched gpui-kit fork. Until they are published, language repos pin levain by git revision.
- Every host is built for Linux (x64, arm64), macOS (arm64, x64), Windows (x64, arm64), iOS (device, simulator) and Android (arm64, x86\_64), from one levain revision.
- All five platforms are in M1. levain adds Windows, which baguette lacks. baguette's host already has Windows code paths (loading `beam.smp.dll`, a manifest workaround in `build.rs`), so the gaps are likely in startup and packaging, not rendering; this is unverified.

## M0: extraction

Gate: **baguette's `mix test`, `cargo test` and the counter's end-to-end test pass unchanged against levain at a pinned revision; the wire format does not change.** Steps are test first, as in baguette.

1. Create Ziinc/levain with the workspace and CI on all five platforms.
2. Move `baguette_abi` to `levain-abi`; rename symbols, `ABI_VERSION` 4.
3. Move the host modules into `levain`, with their unit tests and the conformance fixtures.
4. Add the `Runtime` trait; turn `beam.rs` into baguette's BEAM runtime crate implementing it.
5. Shrink `baguette_host` to `levain::run(Beam, tauri::generate_context!())`.
6. Port host selection, checksums, bundling and iOS/Android project generation from `release.ex` to `levain-pack`; the mix tasks call it.
7. Windows: the counter builds and runs, then passes its end-to-end test.

| Work | Estimate (rough) |
| --- | --- |
| Steps 1–5: workspace, ABI, modules, Runtime trait | 2–3 weeks |
| Step 6: `levain-pack` | 2–4 weeks |
| Step 7: Windows | 2–4 weeks, unverified until a first build |

## Open questions

- [x] What blocks baguette on Windows today: BEAM startup, packaging, or both? Nothing blocked it.
- [x] Does `levain-pack` ship in M0, or does baguette keep `release.ex` until chouquette needs packaging in M1? It ships in M0.
- [ ] Which `events.json` cases make up the first conformance set?
- [ ] When can tauri-plugin-gpui, gpui-playwright and the gpui-kit patches be published, so levain can go to crates.io?
