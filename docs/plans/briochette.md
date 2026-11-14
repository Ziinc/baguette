# Briochette

Plan, as of 13 Nov 2026.

Briochette lets you write a native GPUI app entirely in Python. Python owns state, views and tests; a shared Rust host (extracted from baguette) embeds CPython and draws through tauri-plugin-gpui. Apps write no Rust.

Briochette is part of the **Boulangerie project**: baguette (Elixir), chouquette (TS/JS) and briochette (Python) on one shared host, levain. Documentation lives at [boulangerie.tznc.dev](https://boulangerie.tznc.dev).

## Principles

These carry over from baguette unchanged. Only the language-facing layer is new.

- **Python owns everything but pixels.** State, views, styling and tests live in Python. GPUI only renders.
- **The UI is data.** Python sends a node tree, then patches (`replace`, `attrs`, `splice`). It never runs inside a GPUI frame.
- **Same vocabulary as baguette.** HTML tags, Tailwind-style classes, theme tokens, `<list>`, `<canvas>`, `<icon>`, ARIA roles. Same wire format, so one host draws all three languages.
- **Tauri owns the process.** tauri-plugin-gpui attaches GPUI to Tauri windows; the host owns the main thread. Python runs on its own thread.
- **Per-frame logic stays in Rust.** Native components in component sets, exposed to Python through a manifest.
- **Apps ship no Rust toolchain.** A precompiled host, pinned by SHA-256, plus the app's Python and its dependencies.
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

The shared host is **levain**, a Rust workspace of three crates: `levain` (renderer, bridge, platform, `Runtime` trait), `levain-abi` (the C ABI) and `levain-pack` (packaging CLI). All three names were free on crates.io on 13 Nov 2026. App developers never install it: the `briochette` wheels on PyPI bundle the prebuilt host and `levain-pack` per platform.

## Decision: embedding CPython

Decided: **the host embeds CPython**, as baguette's host links the BEAM. RustPython was ruled out: it cannot load C extensions (numpy, pydantic-core) and is slower.

- python-build-standalone's `libpython` is linked into the host. The `_briochette` module is built in with PyO3 (`append_to_inittab`), the way iOS links baguette's NIF statically.
- App code runs on a dedicated Python thread, which Qt code treats as its GUI thread. Host events arrive through `call_soon_threadsafe`.
- The GIL is fine: Python never runs inside a frame. Free-threaded 3.14t is optional, later.
- Mobile uses CPython 3.13+'s official iOS (PEP 730) and Android (PEP 738) builds. Native extensions need mobile wheels there, the analog of baguette's iOS NIF rebuilds.

## Authoring API

Decided: **a PyQt6-compatible subset.** Existing PyQt6 code runs after an import change. Briochette implements the Qt API in Python and renders widgets through the shared host; it does not link Qt.

```python
from briochette.widgets import QApplication, QWidget, QVBoxLayout, QLabel, QPushButton
from briochette.gui import QShortcut, QKeySequence

class Counter(QWidget):
    def __init__(self):
        super().__init__()
        self.count = 0
        self.label = QLabel("Count: 0")
        self.increment = QPushButton("+")
        self.increment.setAccessibleName("Increment")
        self.increment.clicked.connect(self.inc)
        layout = QVBoxLayout(self)
        layout.addWidget(self.label)
        layout.addWidget(self.increment)
        QShortcut(QKeySequence("Ctrl+R"), self, activated=self.reset)

    def inc(self):
        self.count += 1
        self.label.setText(f"Count: {self.count}")

    def reset(self):
        self.count = 0
        self.label.setText("Count: 0")

app = QApplication([])
window = Counter()
window.setWindowTitle("Counter")
window.show()
app.exec()
```

Qt is retained-mode, so no tree diff runs: each widget owns one host node, and a setter (`setText`, `setEnabled`, `setVisible`) sends an `attrs` or `replace` patch for that node only.

| Qt | Briochette |
| --- | --- |
| `QWidget` tree, `show()`, `setWindowTitle` | Retained Python objects; a top-level widget opens a window |
| `QVBoxLayout`, `QHBoxLayout`, `QGridLayout`, stretch, spacing, margins | `flex-col`, `flex-row`, grid; stretch becomes `flex-grow` |
| `QLabel`, `QPushButton`, `QLineEdit`, `QCheckBox`, `QRadioButton`, `QProgressBar` | Host text, button, and gpui-kit input, checkbox and progress |
| `QComboBox`, `QDialog`, `QTabWidget` | gpui-kit select, dialog and tabs, once baguette ships them |
| Signals and slots, `pyqtSignal` | Pure-Python signals; host events emit `clicked`, `textChanged`, … |
| `QApplication.exec`, `QTimer`, `QThread` | asyncio loop on the Python thread; `QThread` signals are queued back to it |
| `QShortcut`, `QAction`, `QMenuBar` | Keymaps and native menus |
| `QListView` + `QAbstractListModel` | Virtualized `<list>` rows, fetched by range |
| `QFileDialog`, `QClipboard`, `QMessageBox` | Platform calls (native dialogs) |
| `QPainter` in `paintEvent` | Later: canvas paint commands |
| Qt Style Sheets | Later: a subset mapped to classes; theme tokens first |
| QML, Qt Quick | Out of scope |

- Modules are `briochette.widgets`, `briochette.gui` and `briochette.core`; class and method names follow Qt's. They are not named `QtWidgets` etc., to keep the Qt trademark out of our names.
- An opt-in compatibility hook makes `from PyQt6.QtWidgets import …` and `from PySide6.QtWidgets import …` resolve to briochette, so existing code runs unchanged. PySide6 needs only aliases on top: `Signal`, `Slot` and `Property` for PyQt's `pyqtSignal`, `pyqtSlot` and `pyqtProperty`.
- Compatibility is measured by a conformance suite of small PyQt6 and PySide6 programs, each with a test, grown widget by widget.

## Qt licensing and trademarks

Verdict: **low risk on copyright if we copy no code or docs; real care needed with names.** This is my reading, not legal advice; counsel reviews it before the public launch.

| Area | Position | What briochette does |
| --- | --- | --- |
| Qt, PyQt6, PySide6 code | Qt is LGPLv3/GPL/commercial, PyQt6 GPLv3/commercial, PySide6 LGPLv3/commercial | Links none of them. Clean-room: built from documented behaviour; no source, docstrings or `.pyi` stubs copied |
| The API (class, method and signal names) | US: [Google v. Oracle](https://www.mccarter.com/insights/all-is-fair-in-google-and-oracle-supreme-court-says-googles-copying-was-fair-use-in-landmark-copyright-case/) (2021) held reimplementing the Java API was fair use, without ruling on copyrightability. EU: [SAS v. World Programming](https://en.wikipedia.org/wiki/SAS_Institute_Inc_v_World_Programming_Ltd) (CJEU, 2012): a program's functionality and programming language are not protected by copyright | Reimplements names and signatures only |
| Documentation | Manuals are protected: in SAS, WPL's manual infringed by copying SAS's text | Writes its own docs |
| "Qt" trademark | [The Qt Company's guidelines](https://www.qt.io/trademark) bar Qt in product or domain names and ask for ® on first use plus an ownership legend | Names stay briochette; docs say "Qt®-compatible" with the legend; no Qt logo |
| PyQt6 and PySide6 names | Owned by Riverbank Computing and The Qt Company | We publish no package with those names; the hook is opt-in and runtime-only |
| Conformance programs | Qt's and PySide's examples carry their own licence headers | Reuse one only after checking its header; otherwise write our own |

A side effect for users: a PyQt6 app running on briochette no longer links GPL code.

## Testing

Each layer maps onto one of your existing GPUI libraries. Order per feature stays TDD as in baguette: Rust unit test, headless test, then one end-to-end test.

| Layer | Briochette API | Built on | Runs in |
| --- | --- | --- | --- |
| Headless | A pytest-qt-compatible `qtbot` fixture (`mouseClick`, `keyClicks`, `waitSignal`), plus by-role queries | Testing Library vocabulary, as gpui-testing-library; port of `Baguette.Test` | pytest, no host |
| End to end | playwright-python (sync or async) with `connect()` | gpui-playwright (already supports Python clients) | Built app under `xvfb-run` |
| Property | Hypothesis `RuleBasedStateMachine` over the headless widgets | Same oracles as gpui-proptest | pytest |
| Visual | Screenshot plus plain-English expectations | gpui-visual-test's CLI and judges | CI |
| Styleguide | Example widgets with knobs | gpui-styleguidist (needs a non-Rust example source) | Later |

- The `playwright` host feature and `GPUI_PLAYWRIGHT` env var work as in baguette.
- Shared conformance fixtures (`patches.json`, `components.json`, plus a new `events.json`) are tested by the Rust host and all three language libraries.

Mobile CI from M1: every end-to-end test also runs on the iOS simulator and the Android emulator, which baguette's CI already boots. gpui-playwright reaches the app over the simulator's shared localhost on iOS and `adb forward` on Android. If its server does not build for mobile yet, that is M1 work.

## Packaging and platforms

`briochette build` does what `mix release` plus `Baguette.Release.package/1` do, with no Rust compile on the default host.

1. Resolve the app's dependencies with uv into a release `site-packages`.
2. Add a pinned python-build-standalone runtime (SHA-256 checked, as `liberlang.a`).
3. Slim it: precompile to `.pyc`, drop tests, docs and unused stdlib modules (`idlelib`, `tkinter`, `ensurepip`), and report what went in a `slim.json`, as `Baguette.Release.Slim`.
4. Fetch the precompiled host, which ships inside the `briochette` wheel per platform.
5. Write `briochette.json` (window, component sets), then `tauri bundle`.

| Platform | Plan |
| --- | --- |
| Linux, macOS | M1, as baguette |
| Android, iOS | M1, with desktop: CPython's official iOS and Android builds, app embedded in the host library. Pure-Python deps work; native ones need mobile wheels |
| Windows | M1, with the rest. levain adds Windows, which baguette lacks; tauri-plugin-gpui already handles Windows input, IME and menus, and wgpu renders through DX12 |

Dev loop: `briochette dev` runs the host against your venv and restarts the interpreter on save, keeping windows open.

## Dependencies

Decided: **briochette builds no third-party packages.** Users declare dependencies in a normal `pyproject.toml` (`uv add httpx`, or a path dependency for their own code). Whatever installs from PyPI works; anything else is the user's to build.

- **Desktop:** plain CPython, so PyPI works as anywhere.
- **Mobile, pure-Python packages** (`py3-none-any`): work unchanged.
- **Mobile, packages with compiled code:** used only if a wheel exists for the target's tag (PEP 730 iOS, PEP 738 Android). If none exists, `briochette build` stops and names each package and the tag it needs.
- **Bring your own wheels:** users build missing ones themselves (cibuildwheel supports iOS since 3.0 and Android since 3.1) and point briochette at a local folder or private index, e.g. `[tool.briochette] wheels = "wheels/"`. Their own native packages go the same way.
- **Popular packages that don't work on mobile out of the box get no special handling.** Today that includes numpy and pydantic: neither publishes iOS or Android wheels on PyPI (checked 13 Nov 2026).

* **Third-party mobile indexes:** users may add them like any extra index, at their own risk. As of 13 Nov 2026, [BeeWare's index](https://pypi.anaconda.org/beeware/simple/numpy/) has numpy 2.5.2.post1 for iOS (Python 3.13–3.15), and Chaquopy's has numpy 1.26.2 for Android. Neither has pydantic-core; pydantic v1 is pure Python and works.
* **Later, not MVP:** a first-party paid index of mobile wheels that we maintain.

### Guide: build a mobile wheel yourself

Ships with the docs, for any package with compiled code that has no iOS or Android wheel.

1. Install cibuildwheel 3.1 or later (iOS support since 3.0, Android since 3.1).
2. In the package's source folder, build for the target: on a Mac with Xcode, `cibuildwheel --platform ios`; on Linux or macOS with the Android SDK and NDK, `cibuildwheel --platform android`.
3. Build only the Python you ship: `CIBW_BUILD="cp313-*"`.
4. Rust packages (maturin) build the same way once the Rust targets are installed (`rustup target add aarch64-apple-ios aarch64-linux-android …`).
5. Copy the wheels from `wheelhouse/` into the app's `wheels/` folder, or upload them to a private index.
6. `briochette build --target ios` (or `android`) picks them up from `[tool.briochette] wheels`.

Where builds usually fail: system libraries the package expects to find, Fortran code, and build steps that run freshly compiled tools on the build machine.

What briochette still owns, because no wheel can do it: on iOS, `briochette build` moves each extension module into a `.framework` in the app bundle, as CPython's iOS support requires. iOS builds need a Mac with Xcode, as any iOS app does.

Estimate: about 1 week (target-tag resolution, the missing-wheel error, local wheel folders, iOS framework packaging).

## Roadmap

| Milestone | Scope | Gate |
| --- | --- | --- |
| M0 · Extract levain from baguette | Runtime trait, renderer, platform calls and C ABI move into levain | baguette tests pass unchanged; the wire format does not change |
| M1 · Counter on Linux, macOS, Windows, iOS and Android | CPython in the host; QApplication, QWidget, layouts, QLabel, QPushButton, signals | counter e2e passes on all five |
| M2 · Parity with baguette | Qt widget subset: inputs, list models, menus, shortcuts, dialogs, QTimer, QThread | PyQt6 conformance programs pass; todo, board and gallery ported |
| M3 · Test kit | pytest-qt-compatible qtbot, Hypothesis state machines, visual tests | every example has headless and end-to-end tests |
| M4 · Ship | briochette build: uv, python-build-standalone, slimming, host in the wheel | an app ships with no Rust toolchain installed |
| M5 · Store releases | Signing, App Store and Play builds, one release workflow for every platform | an example app passes TestFlight and Play internal testing |
| M6 · Component sets and styleguide | Typed gpui-kit and gpui-bootstrap builders, examples in gpui-styleguidist | .pyi stubs generated from manifests; a mismatched set is refused |

Every milestone is test first: Rust unit test, headless test, then one end-to-end test. M0 is shared with chouquette and lands once.

## Example: counter app

The M1 deliverable, and the first conformance program. One project builds for all five platforms.

```text
counter/
  pyproject.toml
  counter/app.py
  tests/test_counter.py       # headless, no host
  e2e/test_counter_e2e.py     # built app, through gpui-playwright
```

```toml
# pyproject.toml
[project]
name = "counter"
version = "0.1.0"
requires-python = ">=3.13"
dependencies = ["briochette"]

[dependency-groups]
dev = ["pytest", "playwright"]

[tool.briochette]
app = "counter.app:main"
identifier = "com.example.counter"
window = { title = "Counter", width = 360, height = 240 }
```

```python
# counter/app.py
from briochette.widgets import QApplication, QWidget, QVBoxLayout, QLabel, QPushButton

class Counter(QWidget):
    def __init__(self):
        super().__init__()
        self.count = 0
        self.label = QLabel("Count: 0")
        self.increment = QPushButton("+")
        self.increment.setAccessibleName("Increment")
        self.increment.clicked.connect(self.inc)
        layout = QVBoxLayout(self)
        layout.addWidget(self.label)
        layout.addWidget(self.increment)

    def inc(self):
        self.count += 1
        self.label.setText(f"Count: {self.count}")

def main():
    app = QApplication([])
    window = Counter()
    window.show()
    app.exec()
```

```python
# tests/test_counter.py
from briochette.core import Qt
from counter.app import Counter

def test_increments(qtbot):
    window = Counter()
    qtbot.addWidget(window)
    qtbot.mouseClick(window.increment, Qt.MouseButton.LeftButton)
    assert window.label.text() == "Count: 1"
```

```python
# e2e/test_counter_e2e.py
from playwright.sync_api import expect

def test_increments(app_page):  # briochette.testing fixture: launches the built app, connects
    app_page.get_by_role("button", name="Increment").click()
    expect(app_page.get_by_text("Count: 1")).to_be_visible()
```

```sh
uv run pytest tests                  # headless
briochette dev                       # desktop, restarts on save
briochette build --target windows    # or linux, macos, ios, android
briochette e2e --target android      # build with the playwright feature, boot the emulator, run e2e/
```

## Open questions

- [x] GitHub owner for levain, chouquette and briochette (and baguette): Ziinc or tznc?

  Decided: all repos stay under Ziinc, as personal open-source work. Move to an org only if a community forms.
- [ ] Counsel review of the Qt licensing and trademark position before the public launch.
- [ ] Ship the PySide6 hook in v1 alongside PyQt6? Recommended: yes, it is mostly aliases.
- [ ] Which PyQt6 and PySide6 programs make up the first conformance suite, after the counter?
