defmodule Baguette.CallsTest do
  # The platform calls the app sends the native host, against levain's
  # conformance fixture (test/fixtures/calls.json, kept equal to levain's by
  # CI). Levain parses each valid case with its real request parser; here the
  # Elixir function for each call must send a request of the same shape: the
  # call's name and the keys of its args.
  #
  # What is sent is read off the message `Baguette.Host` receives (a trace on
  # the headless host), since without a native host nothing else shows it.
  use ExUnit.Case, async: false

  alias Baguette.{App, CLI, Clipboard, Host, Menu, Window}

  @fixture "test/fixtures/calls.json"
  @external_resource @fixture
  @cases @fixture |> File.read!() |> JSON.decode!()
  @valid for %{"json" => %{"call" => _}} = c <- @cases, not is_map_key(c, "reply"), do: c

  # The Elixir function behind each valid fixture case, by its name.
  @senders %{
    "clipboard.read" => &Clipboard.read/0,
    "clipboard.write" => &__MODULE__.write/0,
    "app.appearance" => &App.appearance/0,
    "app.open_url" => &__MODULE__.open_url/0,
    "menu.set" => &__MODULE__.menu_set/0,
    "window.open" => &__MODULE__.window_open/0,
    "window.open with defaults" => &__MODULE__.window_open_defaults/0,
    "window.close" => &__MODULE__.window_close/0,
    "window.set_title" => &__MODULE__.window_set_title/0,
    "window.set_bounds, size and position" => &__MODULE__.window_bounds/0,
    "window.set_bounds, size only" => &__MODULE__.window_bounds_size/0,
    "window.info" => &__MODULE__.window_info/0,
    "cli.matches" => &CLI.matches/0,
    "app.exit with a code" => &__MODULE__.exit_with_code/0,
    "app.exit without a code" => &__MODULE__.exit_without_code/0
  }

  def write, do: Clipboard.write("copied")
  def open_url, do: App.open_url("https://example.com")

  def menu_set do
    Menu.set([
      {"File", [{"New job", "new_job", keys: "secondary-n"}, :separator, {"Quit", "quit"}]}
    ])
  end

  def window_open, do: Window.open(4, title: "Details", width: 400, height: 300)
  def window_open_defaults, do: Window.open(1)
  def window_close, do: Window.close(4)
  def window_set_title, do: Window.set_title(0, "Jobs (3)")
  def window_bounds, do: Window.set_bounds(0, x: 10, y: 20, width: 800, height: 600)
  def window_bounds_size, do: Window.set_bounds(2, width: 640.5)
  def window_info, do: Window.info(0)
  def exit_with_code, do: App.exit(2)
  def exit_without_code, do: App.exit()

  setup do
    Host.reset_platform()
    on_exit(&Host.reset_platform/0)

    :erlang.trace(Process.whereis(Host), true, [:receive, {:tracer, self()}])
    :ok
  end

  # Replaces every value by its type, keeping the keys.
  defp shape(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), shape(v)} end)
  defp shape(list) when is_list(list), do: Enum.map(list, &shape/1)
  defp shape(n) when is_number(n), do: :number
  defp shape(b) when is_binary(b), do: :string
  defp shape(b) when is_boolean(b), do: :boolean
  defp shape(nil), do: nil

  # What the host was asked, from this process: `{call, args}`.
  defp sent do
    me = self()

    receive do
      {:trace, _host, :receive, {:"$gen_call", {^me, _}, {:call, name, args}}} ->
        {name, args}

      {:trace, _host, :receive, {:"$gen_call", {^me, _}, {:call, name, args, _mode}}} ->
        {name, args}
    after
      1_000 -> flunk("no platform call was sent")
    end
  end

  test "the fixture has a case for each of the twelve calls" do
    calls = @valid |> Enum.map(& &1["json"]["call"]) |> Enum.uniq() |> Enum.sort()

    assert calls ==
             ~w(app.appearance app.exit app.open_url cli.matches clipboard.read clipboard.write menu.set window.close window.info window.open window.set_bounds window.set_title)
  end

  test "every call the library makes is in the fixture, and each fixture call has a function" do
    made =
      for file <- Path.wildcard("lib/**/*.ex"),
          [_, call] <- Regex.scan(~r/\bcall\(\s*"([a-z]+\.[a-z_]+)"/, File.read!(file)),
          uniq: true,
          do: call

    assert Enum.sort(made) ==
             @valid |> Enum.map(& &1["json"]["call"]) |> Enum.uniq() |> Enum.sort()
  end

  for %{"name" => name, "json" => json} <- @valid do
    test "#{name} sends the request in the fixture" do
      json = unquote(Macro.escape(json))
      name = unquote(name)
      sender = Map.fetch!(@senders, name)

      sender.()

      {call, args} = sent()
      assert call == json["call"]
      assert shape(args) == shape(json["args"])
    end
  end
end
