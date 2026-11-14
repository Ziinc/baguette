# Chouquette

Plan, as of 13 Nov 2026.

Chouquette lets you write a native GPUI app entirely in TypeScript or JavaScript. TSX describes the UI; a shared Rust host (extracted from baguette) draws it through tauri-plugin-gpui. Apps write no Rust.

Chouquette is part of the **Boulangerie project**: baguette (Elixir), chouquette (TS/JS) and briochette (Python) on one shared host, levain. Documentation lives at [boulangerie.tznc.dev](https://boulangerie.tznc.dev).

## Principles

These carry over from baguette unchanged. Only the language-facing layer is new.

- **The language owns everything but pixels.** State, views, styling and tests live in TS/JS. GPUI only renders.
- **The UI is data.** JS sends a node tree, then patches (`replace`, `attrs`, `splice`). It never runs inside a GPUI frame.
- **Same vocabulary as baguette.** HTML tags, Tailwind-style classes, theme tokens, `<list>`, `<canvas>`, `<icon>`, ARIA roles. Same wire format, so the same host draws all three languages.
- **Tauri owns the process.** tauri-plugin-gpui attaches GPUI to Tauri windows; the host owns the main thread on every platform.
- **Per-frame logic stays in Rust.** Anything that must run every frame is a native component in a component set, exposed to JS through a manifest.
- **Apps ship no Rust toolchain.** A precompiled host, pinned by SHA-256, plus the app's JS bundle.
- **Every platform from day one.** Linux, macOS, Windows, iOS and Android are in every milestone's gate, starting at M1. A feature is done only when it runs on all five (mobile on the simulator and emulator).
- **Tests resemble use.** Headless tests by role and name; end-to-end through gpui-playwright.

## Architecture

```text
baguette (Elixir)     chouquette (TS/JS)      briochette (Python)
HEEx views            React (reconciler)      PyQt6-compatible widgets
BEAM (liberlang)      QuickJS; Node for Next  CPython
        \                    |                      /
         trees, patches, calls  v      ^  events, call replies
+-------------------------------------------------------------------+
| levain: the shared Rust host, extracted from baguette             |
|  C ABI (levain-abi) | renderer | platform calls | component sets   |
+-------------------------------------------------------------------+
                              |
        tauri-plugin-gpui: Tauri owns the event loop and windows;
                  GPUI renders into them via wgpu
```

Only the top row is new per language. The host, C ABI and tauri-plugin-gpui come out of baguette and are shared by all three, so a renderer fix lands everywhere at once.

The shared host is **levain**, a Rust workspace of three crates: `levain` (renderer, bridge, platform, `Runtime` trait), `levain-abi` (the C ABI) and `levain-pack` (packaging CLI). All three names were free on crates.io on 13 Nov 2026. App developers never install it: the `chouquette` npm package bundles its prebuilt hosts and `levain-pack` per platform.

## Decision: JS runtimes

Decided: **QuickJS first, embedded in the host.** An embedded **Node** runtime follows for Next.js, behind the same `Runtime` trait. Both run on a JS thread, and the host keeps the main thread.

| Runtime | Ships in | For | Mobile | Size | Node APIs |
| --- | --- | --- | --- | --- | --- |
| QuickJS-jit (`rquickjs`, as gpui-shell) | M1 | Plain React apps | Yes (no JIT needed on iOS) | \~+2 MB | Only those the host grants as capabilities |
| Node, embedded (libnode everywhere; on iOS/Android the fogtape nodejs-mobile fork (Node 26) first, our own builds later) | M7 | Next.js apps, npm packages that need Node | iOS runs V8 jitless | \~+90–120 MB uncompressed | Full |

- One app picks one runtime in `chouquette.json`. The wire protocol and C ABI are the same for both.
- Node is embedded with its own libuv loop on the JS thread; it never opens a port.

Decided: **embed libnode on desktop and mobile, starting mobile from the [fogtape/nodejs-mobile](https://github.com/fogtape/nodejs-mobile/releases/tag/v26.10.0-0) fork (Node 26).** Official nodejs-mobile stops at Node 18.20.4, which is past end of life and too old for Next 16. We test the fork first; our own builds, or our own patched versions, come later and replace it behind the same `Runtime` trait.

- Desktop: we build Node as a shared library (`--shared`) ourselves; Node publishes no prebuilt libnode. A `libnode` CI workflow pins each build by SHA-256, as baguette's `liberlang` workflow does.
- Mobile: the fork's iOS and Android libraries are vendored and pinned by SHA-256. On iOS, V8 runs `--jitless`, which App Store rules require; Android keeps the JIT.
- Spike first: the counter app, then a `create-next-app` starter, on the fork in the iOS simulator and the Android emulator. Spike gate: both render and handle a click, with the shim unchanged from desktop.

Estimate, one engineer (rough):

| Work | Estimate |
| --- | --- |
| Desktop: libnode build workflow, C++ shim and Rust FFI, host and `chouquette build` integration | 3–5 weeks |
| Mobile on the fork: vendor and pin, link into iOS and Android hosts, simulator and emulator CI | 2–4 weeks |
| Later, our own mobile builds: port nodejs-mobile patches to a pinned LTS, iOS and Android | 5–9 weeks |
| Per Node major after that | \~1 week |

CI build time dominates iteration: a full Node build is about 30–60 min per desktop target, longer for mobile, so caching starts on day one. The Next.js adapter (M7) is not included.

## Authoring API

Decided: **React**, rendered through a custom `react-reconciler` host config. Its mutations map one to one onto baguette's patch ops, so no tree diff runs in JS.

Components are written as for the web. `@chouquette/react-dom` stands in for `react-dom` (a bundler alias), so `div`, `span`, `p`, `button`, `input`, `img`, `a`, `ul`/`li`, `className`, `onClick` and a `style` subset map onto baguette's elements. This is what lets plain React code and Next.js apps run with few changes.

```tsx
// app.tsx
import { useState } from "react";
import { createRoot } from "react-dom/client"; // aliased to @chouquette/react-dom
import { useKeymap } from "chouquette";

function Counter() {
  const [count, setCount] = useState(0);
  useKeymap("secondary-r", () => setCount(0));
  return (
    <div className="size-full flex-col items-center justify-center gap-6 bg-background">
      <p className="text-3xl font-bold">Count: {count}</p>
      <button className="px-4 py-2 rounded-md bg-primary" aria-label="Increment"
        onClick={() => setCount(c => c + 1)}>+</button>
    </div>
  );
}

createRoot({ window: 0 }).render(<Counter />);
```

| Baguette | Chouquette |
| --- | --- |
| `Baguette.View` (`mount`, `render`, `handle_event`) | Function components and hooks |
| `class="…"` | `className="…"` (same Tailwind-style classes) |
| `phx-click="inc"` + `phx-value-*` | `onClick={fn}`; the wire still sends `phx-click="<handler id>"` and the runtime dispatches |
| `phx-change`, `phx-submit` on `<form>` | `onChange`, `onSubmit` with a `FormData`-like value |
| `<list rows phx-rows>` + `handle_rows/3` | `<List rows={n} renderRow={i => …} />` |
| `keymap "secondary-k", :open` + `handle_action/2` | `useKeymap(keys, fn, { context })` |
| `Baguette.Clipboard`, `Window`, `Menu`, `App` | `clipboard`, `windows`, `menu`, `app`: async functions returning Promises |
| `use Baguette.Components, manifest: …` | Generated `.d.ts` per component set: typed `<kit-tag>` etc. |
| `handle_info({:appearance, :dark})` | `useAppearance()` |

## Next.js on chouquette

Goal: build an existing Next.js app with a chouquette plugin (`withChouquette(nextConfig)`) and run it as a native app, with little app code changed. It runs on the embedded Node runtime.

1. **Rendering.** `react-dom` is aliased to `@chouquette/react-dom`, so client components render to host elements. There is no HTML SSR and no hydration.
2. **Client runtime.** Next's App Router and Pages Router run against an in-memory `window.location` and `history`, plus a minimal `document` (title, metadata). `next/link`, `next/navigation` and `next/router` work unchanged.
3. **Server.** Next's request handler runs in the same Node, with no HTTP port. Same-origin `fetch`, RSC payload requests, route handlers and server actions are dispatched in-process.
4. **Server components.** The Flight payload streams in-process from the server half to the client half; `react-server-dom-webpack/client` turns it into elements the reconciler renders.

| Next.js feature | v1 | Notes |
| --- | --- | --- |
| App Router: layouts, loading, error, not-found | Yes | In-memory router |
| Client components | Yes | DOM elements mapped; Tailwind classes map directly |
| Server components | Yes | Rendered in-process |
| Route handlers, server actions | Yes | Called in-process; full Node APIs |
| Pages Router: `getServerSideProps`, `getStaticProps` | Yes | Data functions run in-process |
| `next/image` | Partial | Becomes `<img>` once baguette ships `img`; no image optimizer |
| CSS modules, global CSS, CSS-in-JS, `next/font` | No | GPUI has no CSS engine; Tailwind classes only |
| DOM-heavy libraries (Radix, shadcn/ui, DOM refs, portals, `ResizeObserver`) | No | Need shims or gpui-kit equivalents (dialog, select, popover) |
| Middleware | Later |  |

"Small changes" therefore means: Tailwind-only styling, no direct DOM access, and gpui-kit components for complex widgets. The M7 gate is a `create-next-app` Tailwind starter that runs with only its config changed.

## Testing

Each layer maps onto one of your existing GPUI libraries. Order per feature stays TDD as in baguette: Rust unit test, headless test, then one end-to-end test.

| Layer | Chouquette API | Built on | Runs in |
| --- | --- | --- | --- |
| Headless | `chouquette/test`: `render(<App/>)`, `getByRole`, `user.click/fill/keydown`, `toBeVisible` | Testing Library vocabulary, as gpui-testing-library; a JS headless host (port of `Baguette.Test`) | Vitest on Node, plus a CI pass under QuickJS to catch engine skew |
| End to end | `@playwright/test` with `connectOptions` | gpui-playwright (already speaks Playwright's protocol) | Built app under `xvfb-run` |
| Property | `fast-check` model-based commands over the headless host | Same oracles as gpui-proptest | Vitest |
| Visual | `toHaveScreenshot()` plus plain-English expectations | gpui-visual-test's CLI and judges | CI |
| Styleguide | `*.stories.tsx` with knobs | gpui-styleguidist (needs a non-Rust example source) | Later |

- The `playwright` host feature and `GPUI_PLAYWRIGHT` env var work as in baguette.
- Shared conformance fixtures (`patches.json`, `components.json`, plus a new `events.json`) are tested by the Rust host and all three language libraries.

Mobile CI from M1: every end-to-end test also runs on the iOS simulator and the Android emulator, which baguette's CI already boots. gpui-playwright reaches the app over the simulator's shared localhost on iOS and `adb forward` on Android. If its server does not build for mobile yet, that is M1 work.

## Packaging and platforms

`chouquette build` does what `mix release` plus `Baguette.Release.package/1` do, with no Rust compile on the default host.

1. Bundle the app to one ESM file (esbuild), tree-shaken; TS types are stripped, not checked.
2. Precompile it to QuickJS bytecode.
3. Fetch the precompiled host for the target, pinned by SHA-256. On npm it ships as per-platform `optionalDependencies` (`@chouquette/host-linux-x64`, …), the esbuild pattern.
4. Write `chouquette.json` (window title, size, component sets), as `baguette.json`.
5. `tauri bundle` around host + bundle (deb, AppImage, `.app`, later MSI).

| Platform | Plan |
| --- | --- |
| Linux, macOS | M1, as baguette |
| Android, iOS | M1, with desktop: bundle embedded in the host library, as baguette embeds its release; no JIT on iOS is fine for QuickJS |
| Windows | M1, with the rest. levain adds Windows, which baguette lacks; tauri-plugin-gpui already handles Windows input, IME and menus, and wgpu renders through DX12 |

Dev loop: `chouquette dev` watches, rebundles and reloads the JS context in the running host, keeping windows open.

## Roadmap

| Milestone | Scope | Gate |
| --- | --- | --- |
| M0 · Extract levain from baguette | Runtime trait, renderer, platform calls and C ABI move into levain | baguette tests pass unchanged; the wire format does not change |
| M1 · Counter on Linux, macOS, Windows, iOS and Android | QuickJS in the host, the React reconciler, click events | counter e2e passes on all five |
| M2 · Parity with baguette | Forms, long lists, keymaps, canvas, animation, platform calls | todo, board and gallery examples ported; shared fixtures pass |
| M3 · Test kit | chouquette/test, fast-check model tests, visual tests | every example has headless and end-to-end tests |
| M4 · Ship | chouquette build, precompiled hosts on npm, tauri bundle | an app ships with no Rust toolchain installed |
| M5 · Store releases | Signing, App Store and Play builds, one release workflow for every platform | an example app passes TestFlight and Play internal testing |
| M6 · Component sets and styleguide | Typed gpui-kit and gpui-bootstrap tags, stories in gpui-styleguidist | .d.ts generated from manifests; a mismatched set is refused |
| M7 · Next.js on an embedded Node runtime | libnode (fogtape fork on mobile), @chouquette/react-dom, withChouquette, in-process RSC | a create-next-app Tailwind starter runs on desktop, iOS and Android, config changes only |

Every milestone is test first: Rust unit test, headless test, then one end-to-end test. M0 is shared with briochette and lands once.

## Example: counter app

The M1 deliverable. One project builds for all five platforms on QuickJS.

```text
counter/
  package.json
  chouquette.json
  src/counter.tsx
  src/app.tsx
  src/counter.test.tsx     # headless, no host
  e2e/counter.spec.ts      # built app, through gpui-playwright
```

```json
// package.json
{
  "name": "counter",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "chouquette dev",
    "build": "chouquette build",
    "test": "vitest",
    "e2e": "chouquette e2e"
  },
  "dependencies": { "chouquette": "^0.1.0", "react": "^19.0.0" },
  "devDependencies": { "@playwright/test": "^1.50.0", "typescript": "^5.6.0", "vitest": "^3.0.0" }
}
```

```json
// chouquette.json
{
  "entry": "src/app.tsx",
  "runtime": "quickjs",
  "identifier": "com.example.counter",
  "window": { "title": "Counter", "width": 360, "height": 240 }
}
```

```tsx
// src/counter.tsx
import { useState } from "react";

export function Counter() {
  const [count, setCount] = useState(0);
  return (
    <div className="size-full flex-col items-center justify-center gap-6 bg-background">
      <p className="text-3xl font-bold">Count: {count}</p>
      <button className="px-4 py-2 rounded-md bg-primary" aria-label="Increment"
        onClick={() => setCount(c => c + 1)}>+</button>
    </div>
  );
}
```

```tsx
// src/app.tsx
import { createRoot } from "react-dom/client"; // aliased to @chouquette/react-dom
import { Counter } from "./counter";

createRoot({ window: 0 }).render(<Counter />);
```

```tsx
// src/counter.test.tsx
import { render, screen, user } from "chouquette/test";
import { expect, test } from "vitest";
import { Counter } from "./counter";

test("increments", async () => {
  render(<Counter />);
  await user.click(screen.getByRole("button", { name: "Increment" }));
  expect(screen.getByText("Count: 1")).toBeVisible();
});
```

```ts
// e2e/counter.spec.ts — `chouquette e2e` launches the built app and sets connectOptions
import { expect, test } from "@playwright/test";

test("increments", async ({ page }) => {
  await page.getByRole("button", { name: "Increment" }).click();
  await expect(page.getByText("Count: 1")).toBeVisible();
});
```

```sh
npm test                                # headless
npx chouquette dev                      # desktop, live reload
npx chouquette build --target windows   # or linux, macos, ios, android
npx chouquette e2e --target ios         # build with the playwright feature, boot the simulator, run e2e/
```

## Open questions

- [x] GitHub owner for levain, chouquette and briochette (and baguette): Ziinc or tznc?

  Decided: all repos stay under Ziinc, as personal open-source work. Move to an org only if a community forms.
- [ ] Should chouquette build on `gpui-shell`'s builder API instead of baguette's HTML vocabulary? It would split the host from baguette's.
- [ ] Which Node built-ins does QuickJS get in v1 (fetch, timers, fs)?
- [ ] Which Next.js major to target first (15 or 16), and Turbopack or webpack for the alias?
- [ ] When do we move mobile off the fogtape fork to our own builds, and which Node LTS do we pin then?
