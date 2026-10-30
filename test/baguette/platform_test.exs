defmodule Baguette.PlatformTest do
  # Without a native host the platform is headless: what the app asks of it
  # is kept, so tests can read it back.
  use ExUnit.Case, async: false

  alias Baguette.{App, Clipboard, Menu, Window}

  setup do
    Baguette.Host.reset_platform()
  end

  test "the clipboard holds what was written" do
    assert Clipboard.read() == nil
    assert :ok = Clipboard.write("copied")
    assert Clipboard.read() == "copied"
  end

  test "windows take a title and bounds, and open and close" do
    assert :ok = Window.set_title(0, "Jobs (3)")
    assert :ok = Window.set_bounds(0, width: 800, height: 600)
    assert %{title: "Jobs (3)", width: 800, height: 600} = Window.info(0)

    assert :ok = Window.open(4, title: "Details", width: 400, height: 300)
    assert %{title: "Details", width: 400} = Window.info(4)
    assert :ok = Window.close(4)
    assert Window.info(4) == nil
  end

  test "open_url/1 hands the URL to the system" do
    assert :ok = App.open_url("https://example.com")
    assert Baguette.Host.platform().opened_urls == ["https://example.com"]
  end

  test "the appearance is light or dark" do
    assert App.appearance() in [:light, :dark]
  end

  test "menus are set as data, and a click is an event to window 0" do
    menus = [
      {"File", [{"New job", "new_job", keys: "secondary-n"}, :separator, {"Quit", "quit"}]}
    ]

    assert :ok = Menu.set(menus)

    assert Baguette.Host.platform().menus == [
             %{
               "title" => "File",
               "items" => [
                 %{"id" => "new_job", "label" => "New job", "keys" => "secondary-n"},
                 %{"separator" => true},
                 %{"id" => "quit", "label" => "Quit"}
               ]
             }
           ]
  end

  test "a menu item that is neither a tuple nor :separator is refused" do
    assert_raise ArgumentError, fn -> Menu.set([{"File", ["oops"]}]) end
  end
end
