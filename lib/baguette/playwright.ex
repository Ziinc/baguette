if Code.ensure_loaded?(PlaywrightEx) and Code.ensure_loaded?(WebSockex) do
  defmodule Baguette.Playwright do
    @moduledoc """
    End-to-end tests of a real Baguette app through
    [gpui-playwright](https://github.com/ziinc/gpui-playwright), from ExUnit.

    Build the release with the host's `playwright` feature
    (`BAGUETTE_HOST_FEATURES=playwright mix release`), then:

        app = Baguette.Playwright.start_app!("_build/prod/rel/my_app/bin/my_app_app")
        on_exit(fn -> Baguette.Playwright.stop_app(app) end)
        page = Baguette.Playwright.connect!(app)

        Baguette.Playwright.click(page, "Increment")
        assert :ok = Baguette.Playwright.await_text(page, "Count: 1")

    `page.frame` and `page.opts` work with any `PlaywrightEx.Frame` function
    for what these helpers do not cover. Needs the optional `playwright_ex`
    and `websockex` dependencies.
    """

    alias PlaywrightEx.{Browser, BrowserContext, Frame}

    @timeout 10_000

    @type app :: %{os_pid: non_neg_integer(), port: :inet.port_number()}
    @type page :: %{frame: String.t(), opts: keyword()}

    @doc """
    Starts the app at `path` with gpui-playwright listening on `:port`
    (default 9333) and waits until it accepts connections.
    """
    @spec start_app!(Path.t(), keyword()) :: app()
    def start_app!(path, opts \\ []) do
      port = Keyword.get(opts, :port, 9333)

      os_port =
        Port.open({:spawn_executable, path}, [
          :binary,
          :stderr_to_stdout,
          env: [{~c"GPUI_PLAYWRIGHT", ~c"127.0.0.1:#{port}"}]
        ])

      {:os_pid, os_pid} = Port.info(os_port, :os_pid)
      await_listening!(port, Keyword.get(opts, :timeout, 60_000))
      %{os_pid: os_pid, port: port}
    end

    @doc "Stops an app started by `start_app!/2`."
    @spec stop_app(app()) :: :ok
    def stop_app(%{os_pid: os_pid}) do
      System.cmd("kill", ["#{os_pid}"], stderr_to_stdout: true)
      :ok
    end

    @doc "Connects to the app and returns its main window as a page."
    @spec connect!(app()) :: page()
    def connect!(%{port: port}) do
      name = Module.concat(__MODULE__, "Conn#{System.unique_integer([:positive])}")

      {:ok, _} =
        PlaywrightEx.Supervisor.start_link(
          ws_endpoint: "ws://127.0.0.1:#{port}/",
          timeout: @timeout,
          name: name
        )

      opts = [connection: PlaywrightEx.Supervisor.connection_name(name), timeout: @timeout]
      {:ok, browser} = PlaywrightEx.launch_browser(:chromium, opts)
      {:ok, context} = Browser.new_context(browser.guid, opts)
      {:ok, page} = BrowserContext.new_page(context.guid, opts)
      %{frame: page.main_frame.guid, opts: opts}
    end

    @doc "Clicks the button whose accessible name (`aria-label`) is `label`."
    @spec click(page(), String.t()) :: :ok
    def click(page, label) do
      {:ok, _} = Frame.click(page.frame, page.opts ++ [selector: role("button", label)])
      :ok
    end

    @doc "Waits until `text` is shown, or returns an error after the timeout."
    @spec await_text(page(), String.t()) :: :ok | {:error, term()}
    def await_text(page, text) do
      selector = ~s(internal:text=#{inspect(text)}s)

      case Frame.wait_for_selector(page.frame, page.opts ++ [selector: selector, state: "visible"]) do
        {:ok, _} -> :ok
        error -> error
      end
    end

    defp role(role, name), do: ~s(internal:role=#{role}[name=#{inspect(name)}s])

    defp await_listening!(port, timeout) when timeout <= 0,
      do: raise("the app did not listen for Playwright on port #{port}")

    defp await_listening!(port, timeout) do
      case :gen_tcp.connect(~c"127.0.0.1", port, [], 200) do
        {:ok, socket} ->
          :gen_tcp.close(socket)

        {:error, _} ->
          Process.sleep(200)
          await_listening!(port, timeout - 400)
      end
    end
  end
end
