"""Drives the counter release through AT-SPI (see e2e-linux.sh).

Finds the Increment and Decrement buttons by their aria-labels, clicks them
the way a screen reader would and waits for the count label, rendered from
the state in `Counter.Store`, to follow. Takes a screenshot of the window
before and after.
"""

import subprocess
import sys
import time
import warnings

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

WINDOW_TITLE = "counter"
TIMEOUT = 90
OUT_DIR = sys.argv[1]


def walk(node):
    yield node
    for i in range(node.get_child_count()):
        child = node.get_child_at_index(i)
        if child is not None:
            yield from walk(child)


def find_window():
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        for j in range(app.get_child_count() if app else 0):
            window = app.get_child_at_index(j)
            # GTK's own (empty) window has the same title: pick the one
            # GPUI's tree hangs off.
            if (
                window is not None
                and window.get_name() == WINDOW_TITLE
                and any(n.get_name() == "Increment" for n in walk(window))
            ):
                return window
    return None


def find(window, role, name):
    return next((n for n in walk(window) if n.get_role() == role and n.get_name() == name), None)


def wait_for(what, check):
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        try:
            result = check()
        except gi.repository.GLib.GError:
            result = None
        if result:
            return result
        time.sleep(0.25)
    sys.exit(f"FAIL: timed out waiting for {what}")


def screenshot(name):
    window_id = subprocess.check_output(
        ["xdotool", "search", "--sync", "--name", f"^{WINDOW_TITLE}$"], text=True
    ).split()[-1]
    path = f"{OUT_DIR}/{name}.png"
    subprocess.check_call(["import", "-window", window_id, path])
    print(f"screenshot {path}")


def click(button):
    # Deprecated, but the replacement (`get_localized_name`) is translated.
    warnings.simplefilter("ignore", DeprecationWarning)
    actions = [button.get_action_name(i) for i in range(button.get_n_actions())]
    button.do_action(actions.index("click"))


def main():
    window = wait_for("the counter window on the AT-SPI bus", find_window)
    wait_for("'Count: 0'", lambda: find(window, Atspi.Role.LABEL, "Count: 0"))
    time.sleep(0.5)
    screenshot("counter-start")

    increment = find(window, Atspi.Role.PUSH_BUTTON, "Increment")
    decrement = find(window, Atspi.Role.PUSH_BUTTON, "Decrement")
    if increment is None or decrement is None:
        sys.exit("FAIL: no Increment/Decrement buttons")

    for expected, button in [(1, increment), (2, increment), (3, increment), (2, decrement)]:
        click(button)
        wait_for(f"'Count: {expected}'", lambda: find(window, Atspi.Role.LABEL, f"Count: {expected}"))

    time.sleep(0.5)
    screenshot("counter-after-clicks")
    print("PASS: clicks round-trip through Counter.Store")


if __name__ == "__main__":
    main()
