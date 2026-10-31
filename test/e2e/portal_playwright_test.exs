defmodule Baguette.E2E.PortalPlaywrightTest do
  # The host must not wait on the XDG desktop portal's settings: TAO, with
  # Tauri's default `dbus` feature, read the colour scheme on the main thread
  # for each window and every appearance query, and a portal whose settings
  # never answer (as on CI runners) held the window back 5 s each time.
  # The host reads the portal's colour scheme off the main thread instead.
  # Runs examples/counter and examples/gallery, built with the `playwright`
  # host feature, on a private session bus with a fake portal
  # (test/support/fake_portal.py).
  #
  # A portal that never answers even its property reads also stalls GTK's
  # own startup (GtkApplication reads them, 25 s), as it does any GTK app;
  # that is outside the host, so the fake portal answers those.
  use ExUnit.Case, async: false
  alias Baguette.Playwright

  @moduletag :playwright

  @counter Path.expand("../../examples/counter/_build/prod/rel/counter/bin/counter_app", __DIR__)
  @gallery Path.expand("../../examples/gallery/_build/prod/rel/gallery/bin/gallery_app", __DIR__)
  @fake_portal Path.expand("../support/fake_portal.py", __DIR__)

  test "the window opens at once when the portal's settings never answer" do
    address = session_bus([])
    started = System.monotonic_time(:millisecond)
    app = start_app!(@counter, address)
    page = Playwright.connect!(app)
    assert :ok = Playwright.await_text(page, "Count: 0")
    elapsed = System.monotonic_time(:millisecond) - started

    # One unanswered settings read costs 5 s; starting takes about 1 s.
    assert elapsed < 4_000, "the app took #{elapsed} ms to open its window"
  end

  test "the portal's dark colour scheme reaches the view" do
    app = start_app!(@gallery, session_bus(["--dark"]))
    page = Playwright.connect!(app)
    assert :ok = Playwright.await_text(page, "Appearance: dark")
  end

  defp start_app!(path, address) do
    app = Playwright.start_app!(path, env: [{"DBUS_SESSION_BUS_ADDRESS", address}])
    on_exit(fn -> Playwright.stop_app(app) end)
    app
  end

  # A private session bus with the fake portal on it, gone when the test is.
  # Nothing on it is activatable: other lookups fail at once.
  defp session_bus(portal_args) do
    dir = Path.join(System.tmp_dir!(), "baguette-portal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "services"))
    File.write!(Path.join(dir, "session.conf"), session_conf(dir))

    bus =
      Port.open({:spawn_executable, System.find_executable("dbus-daemon")}, [
        :binary,
        :stderr_to_stdout,
        {:line, 4096},
        args: ["--config-file=#{dir}/session.conf", "--nofork", "--print-address"]
      ])

    address = await_line(bus, &String.starts_with?(&1, "unix:"))

    portal =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :stderr_to_stdout,
        {:line, 4096},
        args: [@fake_portal | portal_args],
        env: [{~c"DBUS_SESSION_BUS_ADDRESS", String.to_charlist(address)}]
      ])

    "ready" = await_line(portal, &(&1 == "ready"))

    on_exit(fn ->
      for port <- [portal, bus], {:os_pid, pid} <- [Port.info(port, :os_pid)] do
        System.cmd("kill", ["#{pid}"], stderr_to_stdout: true)
      end

      File.rm_rf!(dir)
    end)

    address
  end

  defp await_line(port, match?) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        if match?.(line), do: line, else: await_line(port, match?)
    after
      10_000 -> flunk("no matching line from #{inspect(Port.info(port, :name))}")
    end
  end

  defp session_conf(dir) do
    """
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
     "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <busconfig>
      <type>session</type>
      <listen>unix:tmpdir=#{dir}</listen>
      <auth>EXTERNAL</auth>
      <servicedir>#{dir}/services</servicedir>
      <policy context="default">
        <allow send_destination="*" eavesdrop="true"/>
        <allow eavesdrop="true"/>
        <allow own="*"/>
      </policy>
    </busconfig>
    """
  end
end
