defmodule Tally.PlaywrightTest do
  # Drives the real app, the `tally` release built with the `playwright` host
  # feature, through Playwright's protocol: the same locators, actions and
  # auto-waiting assertions a browser test uses, over playwright_ex.
  use ExUnit.Case, async: false
  alias PlaywrightEx.{Browser, BrowserContext, Frame, Page, Selector}

  @moduletag :playwright
  @port 9333
  @timeout 10_000

  setup_all do
    app = Path.expand("../_build/prod/rel/tally/bin/tally_app", __DIR__)

    port =
      Port.open({:spawn_executable, app}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        env: [{~c"GPUI_PLAYWRIGHT", ~c"#{@port}"}]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["#{os_pid}"]) end)

    # Retries until the app is listening.
    start_supervised!(
      {PlaywrightEx.Supervisor, ws_endpoint: "ws://127.0.0.1:#{@port}/", timeout: @timeout}
    )

    # The app is the browser, its window the page.
    {:ok, browser} = PlaywrightEx.launch_browser(:chromium, timeout: @timeout)
    {:ok, context} = Browser.new_context(browser.guid, timeout: @timeout)
    {:ok, page} = BrowserContext.new_page(context.guid, timeout: @timeout)
    %{page: page.guid, frame: page.main_frame.guid}
  end

  setup %{frame: frame} do
    {:ok, _} = Frame.click(frame, selector: Selector.button("Reset"), timeout: @timeout)
    :ok
  end

  test "finds the window by its title and text", %{frame: frame} do
    {:ok, title} = Frame.title(frame, timeout: @timeout)
    assert title =~ "Tally"
    assert has_text?(frame, "Favourite language")
    assert has_text?(frame, "Total: 0")
  end

  test "clicks buttons by role and name", %{frame: frame} do
    vote = &Frame.click(frame, selector: Selector.button("Vote for #{&1}"), timeout: @timeout)
    {:ok, _} = vote.("Elixir")
    {:ok, _} = vote.("Elixir")
    {:ok, _} = vote.("Zig")

    assert has_text?(frame, "Elixir: 2")
    assert has_text?(frame, "Zig: 1")
    assert has_text?(frame, "Total: 3")
  end

  test "reads text content", %{frame: frame} do
    {:ok, _} = Frame.click(frame, selector: Selector.button("Vote for Rust"), timeout: @timeout)
    assert has_text?(frame, "Rust: 1")

    assert {:ok, "Rust: 1"} =
             Frame.text_content(frame, selector: Selector.text("Rust:"), timeout: @timeout)
  end

  test "takes a screenshot", %{page: page} do
    {:ok, png} = Page.screenshot(page, timeout: @timeout)
    assert <<0x89, "PNG", _::binary>> = Base.decode64!(png)
  end

  # Playwright's own `toHaveText`/`toBeVisible`: it retries until the
  # condition holds or the timeout passes.
  defp has_text?(frame, text) do
    Frame.expect(frame,
      selector: Selector.text(text, exact: true),
      expression: "to.be.visible",
      timeout: @timeout
    ) == {:ok, true}
  end
end
