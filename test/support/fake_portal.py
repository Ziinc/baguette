#!/usr/bin/env python3
"""An XDG desktop portal whose settings never answer, or answer dark.

Takes the portal's bus name on the session bus in DBUS_SESSION_BUS_ADDRESS
and serves org.freedesktop.portal.Settings, but never replies to Read,
ReadOne or ReadAll, as a portal does whose settings backend hangs. Property
reads answer, so GTK's own startup (which reads the portal's properties)
goes on; only a colour-scheme lookup waits. With `--dark` it answers
the colour scheme instead, as dark, and other settings with an error.
Prints "ready" once it holds the name.
"""
import sys

from gi.repository import Gio, GLib

NAME = "org.freedesktop.portal.Desktop"
PATH = "/org/freedesktop/portal/desktop"
SETTINGS = """
<node>
  <interface name="org.freedesktop.portal.Settings">
    <method name="Read">
      <arg type="s" direction="in"/><arg type="s" direction="in"/>
      <arg type="v" direction="out"/>
    </method>
    <method name="ReadOne">
      <arg type="s" direction="in"/><arg type="s" direction="in"/>
      <arg type="v" direction="out"/>
    </method>
    <method name="ReadAll">
      <arg type="as" direction="in"/>
      <arg type="a{sa{sv}}" direction="out"/>
    </method>
    <signal name="SettingChanged">
      <arg type="s"/><arg type="s"/><arg type="v"/>
    </signal>
    <property name="version" type="u" access="read"/>
  </interface>
</node>
"""

# Calls never answered, kept so they are not answered with an error either.
held = []


DARK = "--dark" in sys.argv[1:]


def method_call(_conn, _sender, _path, _iface, method, params, invocation):
    if not DARK:
        held.append(invocation)
    elif method in ("Read", "ReadOne") and params.unpack() == (
        "org.freedesktop.appearance",
        "color-scheme",
    ):
        # 1 is prefer-dark. Read, the version 1 method, wraps it once more.
        value = GLib.Variant("u", 1)
        if method == "Read":
            value = GLib.Variant("v", value)
        invocation.return_value(GLib.Variant("(v)", (value,)))
    else:
        invocation.return_dbus_error(
            "org.freedesktop.portal.Error.NotFound", "Requested setting not found"
        )


def get_property(_conn, _sender, _path, _iface, _name):
    return GLib.Variant("u", 2)


def main():
    loop = GLib.MainLoop()
    info = Gio.DBusNodeInfo.new_for_xml(SETTINGS).interfaces[0]

    def bus_acquired(conn, _name):
        conn.register_object(PATH, info, method_call, get_property, None)

    def name_acquired(*_):
        print("ready", flush=True)

    def name_lost(*_):
        print(f"could not own {NAME}", file=sys.stderr, flush=True)
        loop.quit()

    Gio.bus_own_name(
        Gio.BusType.SESSION,
        NAME,
        Gio.BusNameOwnerFlags.NONE,
        bus_acquired,
        name_acquired,
        name_lost,
    )
    loop.run()


if __name__ == "__main__":
    main()
