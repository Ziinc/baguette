if Code.ensure_loaded?(PlaywrightEx) and Code.ensure_loaded?(WebSockex) do
  defmodule Baguette.Playwright do
    @moduledoc """
    End-to-end tests of a real Baguette app through
    [gpui-playwright](https://github.com/ziinc/gpui-playwright), from ExUnit.

    Build the release with the host's `playwright` feature
    (`BAGUETTE_HOST_FEATURES=playwright mix release`), then, under a display
    (`xvfb-run -a mix test` on Linux CI):

        app = Baguette.Playwright.start_app!("_build/prod/rel/my_app/bin/my_app_app")
        on_exit(fn -> Baguette.Playwright.stop_app(app) end)
        page = Baguette.Playwright.connect!(app)

        Baguette.Playwright.fill(page, "Title", "Buy milk")
        Baguette.Playwright.press(page, "Title", "Enter")
        Baguette.Playwright.check(page, "Buy milk")
        assert :ok = Baguette.Playwright.await_text(page, "0 of 1 left")

    ## Targets

    Every action takes a target. A string is the accessible name (the
    `aria-label`, or a label's text) of the role the action implies: a button
    for `click/2`, a textbox for `fill/3`, a checkbox for `check/2`. A keyword
    list builds any locator (see `selector/1`):

        Baguette.Playwright.click(page, role: "button", name: "Delete Buy milk")
        Baguette.Playwright.count(page, role: "listitem")
        Baguette.Playwright.text_content(page, text: "left", exact: false)

    Matching is strict, as in Playwright: a target that matches more than one
    element is an error; add `nth:` to pick one.

    For anything else, `page.page`, `page.frame` and `page.opts` work with any
    `PlaywrightEx.Page` or `PlaywrightEx.Frame` function. Needs the optional
    `playwright_ex` and `websockex` dependencies.
    """

    alias PlaywrightEx.{Browser, BrowserContext, Connection, Frame, Page}

    @timeout 10_000

    @type app :: %{
            os_pid: non_neg_integer(),
            os_port: port(),
            endpoint: String.t(),
            port: :inet.port_number()
          }
    @type page :: %{page: String.t(), frame: String.t(), opts: keyword()}
    @type target :: String.t() | keyword()

    ## The app

    @doc """
    Starts the app at `path` with gpui-playwright listening, and waits until
    it reports its endpoint. Options:

      * `:port` - the port to listen on (default: any free port)
      * `:env` - more environment variables, as `[{"NAME", "value"}]`
      * `:timeout` - how long to wait for the server, in ms (default 60 s)
    """
    @spec start_app!(Path.t(), keyword()) :: app()
    def start_app!(path, opts \\ []) do
      endpoint_file =
        Path.join(System.tmp_dir!(), "baguette-pw-#{System.unique_integer([:positive])}")

      env =
        [
          {"GPUI_PLAYWRIGHT", "127.0.0.1:#{Keyword.get(opts, :port, 0)}"},
          {"GPUI_PLAYWRIGHT_ENDPOINT_FILE", endpoint_file}
          | Keyword.get(opts, :env, [])
        ]
        |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

      os_port = Port.open({:spawn_executable, path}, [:binary, :stderr_to_stdout, env: env])
      {:os_pid, os_pid} = Port.info(os_port, :os_pid)
      endpoint = await_endpoint!(endpoint_file, os_pid, Keyword.get(opts, :timeout, 60_000))
      File.rm(endpoint_file)
      [_, port] = Regex.run(~r{:(\d+)/}, endpoint)
      %{os_pid: os_pid, os_port: os_port, endpoint: endpoint, port: String.to_integer(port)}
    end

    @doc "Stops an app started by `start_app!/2` and waits until it has exited."
    @spec stop_app(app()) :: :ok
    def stop_app(%{os_pid: os_pid}) do
      System.cmd("kill", ["#{os_pid}"], stderr_to_stdout: true)
      await_exit(os_pid, 50)
    end

    @doc """
    What the app has printed (stdout and stderr) since the last call. Call it
    from the process that started the app.
    """
    @spec log(app()) :: String.t()
    def log(%{os_port: os_port}), do: collect_log(os_port, [])

    @doc "Whether the app's process is still running."
    @spec alive?(app()) :: boolean()
    def alive?(%{os_pid: os_pid}),
      do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

    @doc "Connects to the app and returns its main window as a page."
    @spec connect!(app()) :: page()
    def connect!(%{endpoint: endpoint}) do
      name = Module.concat(__MODULE__, "Conn#{System.unique_integer([:positive])}")

      {:ok, _} =
        PlaywrightEx.Supervisor.start_link(ws_endpoint: endpoint, timeout: @timeout, name: name)

      opts = [connection: PlaywrightEx.Supervisor.connection_name(name), timeout: @timeout]
      {:ok, browser} = PlaywrightEx.launch_browser(:chromium, opts)
      {:ok, context} = Browser.new_context(browser.guid, opts)
      {:ok, page} = BrowserContext.new_page(context.guid, opts)
      %{page: page.guid, frame: page.main_frame.guid, opts: opts}
    end

    ## Locators

    @doc """
    A Playwright selector for a keyword target:

      * `role:` and optionally `name:` - `getByRole` (`"button"`, `"textbox"`,
        `"checkbox"`, `"list"`, `"listitem"`, `"heading"`, `"link"`, ...)
      * `text:` - `getByText`
      * `label:` - `getByLabel`
      * `placeholder:` - `getByPlaceholder`
      * `test_id:` - `getByTestId` (the element's path id, such as `"root.0.1"`)
      * `exact:` - exact, case-sensitive matching (default `true`)
      * `nth:` - the nth match, from 0
    """
    @spec selector(keyword()) :: String.t()
    def selector(opts) do
      suffix = if Keyword.get(opts, :exact, true), do: "s", else: "i"

      base =
        cond do
          role = opts[:role] ->
            case opts[:name] do
              nil -> "internal:role=#{role}"
              name -> "internal:role=#{role}[name=#{inspect(name)}#{suffix}]"
            end

          text = opts[:text] ->
            "internal:text=#{inspect(text)}#{suffix}"

          label = opts[:label] ->
            "internal:label=#{inspect(label)}#{suffix}"

          placeholder = opts[:placeholder] ->
            "internal:attr=[placeholder=#{inspect(placeholder)}#{suffix}]"

          test_id = opts[:test_id] ->
            "internal:testid=[data-testid=#{inspect(test_id)}s]"

          true ->
            raise ArgumentError, "a target needs role:, text:, label:, placeholder: or test_id:"
        end

      case opts[:nth] do
        nil -> base
        n -> "#{base} >> nth=#{n}"
      end
    end

    ## Actions

    @doc "Clicks `target` (a string names a button)."
    @spec click(page(), target()) :: :ok
    def click(page, target), do: act(page, :click, target, "button")

    @doc "Replaces the text in `target` (a string names a textbox) with `value`."
    @spec fill(page(), target(), String.t()) :: :ok
    def fill(page, target, value), do: act(page, :fill, target, "textbox", value: value)

    @doc "Empties `target` (a string names a textbox)."
    @spec clear(page(), target()) :: :ok
    def clear(page, target), do: fill(page, target, "")

    @doc ~S'Presses `key` (`"Enter"`, `"Tab"`, `"Control+a"`) in `target` (a string names a textbox).'
    @spec press(page(), target(), String.t()) :: :ok
    def press(page, target, key), do: act(page, :press, target, "textbox", key: key)

    @doc ~S"""
    Presses `key` (`"Escape"`, `"Control+z"`, `"Control+Shift+z"`) on the
    window, wherever focus is, as `phx-window-keydown` hears it.
    `"ControlOrMeta+s"` is Cmd on macOS and Ctrl elsewhere.
    """
    @spec press(page(), String.t()) :: :ok
    def press(page, key) do
      %{} =
        Connection.send(
          page.opts[:connection],
          %{guid: page.page, method: :keyboard_press, params: %{key: key}},
          page.opts[:timeout]
        )

      :ok
    end

    @doc "Types `text` key by key into `target` (a string names a textbox)."
    @spec type(page(), target(), String.t()) :: :ok
    def type(page, target, text), do: act(page, :type, target, "textbox", text: text)

    @doc "Checks `target` (a string names a checkbox); no-op if already checked."
    @spec check(page(), target()) :: :ok
    def check(page, target), do: act(page, :check, target, "checkbox")

    @doc "Unchecks `target` (a string names a checkbox); no-op if already unchecked."
    @spec uncheck(page(), target()) :: :ok
    def uncheck(page, target), do: act(page, :uncheck, target, "checkbox")

    @doc "Focuses `target` (a string names a textbox)."
    @spec focus(page(), target()) :: :ok
    def focus(page, target), do: act(page, :focus, target, "textbox")

    @doc "Hovers the pointer over `target` (a string is a `getByLabel` label)."
    @spec hover(page(), target()) :: :ok
    def hover(page, target), do: act(page, :hover, target, nil)

    @doc """
    Drags `target` (a string is a `getByLabel` label) by `dx`, `dy` pixels
    with the mouse: pressed at its centre, moved in steps and released.
    """
    @spec drag(page(), target(), number(), number()) :: :ok
    def drag(page, target, dx, dy) do
      %{"x" => x, "y" => y, "width" => w, "height" => h} = bounding_box(page, target)
      {from_x, from_y} = {x + w / 2, y + h / 2}
      opts = page.opts

      {:ok, _} = Page.mouse_move(page.page, opts ++ [x: from_x, y: from_y])
      {:ok, _} = Page.mouse_down(page.page, opts)
      {:ok, _} = Page.mouse_move(page.page, opts ++ [x: from_x + dx, y: from_y + dy, steps: 5])
      {:ok, _} = Page.mouse_up(page.page, opts)
      :ok
    end

    @doc """
    Turns the mouse wheel over `target` (a string is a `getByLabel` label) by
    `dx`, `dy` pixels, as a user scrolls a scrolling element.
    """
    @spec scroll(page(), target(), number(), number()) :: :ok
    def scroll(page, target, dx, dy) do
      %{"x" => x, "y" => y, "width" => w, "height" => h} = bounding_box(page, target)
      {:ok, _} = Page.mouse_move(page.page, page.opts ++ [x: x + w / 2, y: y + h / 2])

      %{} =
        Connection.send(
          page.opts[:connection],
          %{guid: page.page, method: :mouse_wheel, params: %{delta_x: dx, delta_y: dy}},
          page.opts[:timeout]
        )

      :ok
    end

    ## Reads

    @doc "The text in `target` (a string names a textbox)."
    @spec input_value(page(), target()) :: String.t()
    def input_value(page, target), do: read(page, :input_value, target, "textbox")

    @doc "Whether `target` (a string names a checkbox) is checked."
    @spec checked?(page(), target()) :: boolean()
    def checked?(page, target), do: read(page, :is_checked, target, "checkbox")

    @doc "Whether `target` (a string is a `getByLabel` label) is visible."
    @spec visible?(page(), target()) :: boolean()
    def visible?(page, target), do: read(page, :is_visible, target, nil)

    @doc "Whether `target` (a string names a button) is enabled."
    @spec enabled?(page(), target()) :: boolean()
    def enabled?(page, target), do: read(page, :is_enabled, target, "button")

    @doc "The text inside `target` (a string is a `getByLabel` label)."
    @spec text_content(page(), target()) :: String.t() | nil
    def text_content(page, target), do: read(page, :text_content, target, nil)

    @doc "The value of attribute `name` on `target` (a string is a `getByLabel` label)."
    @spec attribute(page(), target(), String.t()) :: String.t() | nil
    def attribute(page, target, name),
      do: read(page, :get_attribute, target, nil, name: name)

    @doc "How many elements `target` matches right now (a string is a `getByLabel` label)."
    @spec count(page(), target()) :: non_neg_integer()
    def count(page, target) do
      %{result: %{value: n}} =
        send_frame(page, :query_count, %{selector: to_selector(target, nil)})

      n
    end

    @doc """
    Waits until `text` is shown, or returns an error after `:timeout`
    milliseconds (default 10 s). Exact by default; pass `exact: false` for a
    case-insensitive substring.
    """
    @spec await_text(page(), String.t(), keyword()) :: :ok | {:error, term()}
    def await_text(page, text, opts \\ []) do
      await(page, [text: text] ++ Keyword.take(opts, [:exact]), opts)
    end

    @doc """
    Waits until `target` is in `:state` (`"visible"` by default; also
    `"hidden"`, `"attached"`, `"detached"`), or returns an error after
    `:timeout` ms. A string is a `getByLabel` label.
    """
    @spec await(page(), target(), keyword()) :: :ok | {:error, term()}
    def await(page, target, opts \\ []) do
      wait = Keyword.merge(page.opts, Keyword.take(opts, [:timeout]))
      state = Keyword.get(opts, :state, "visible")

      case Frame.wait_for_selector(
             page.frame,
             wait ++ [selector: to_selector(target, nil), state: state]
           ) do
        {:ok, _} -> :ok
        error -> error
      end
    end

    @doc """
    The window-relative bounds of `target` (a string is a `getByLabel`
    label), as `%{"x", "y", "width", "height"}` in pixels.
    """
    @spec bounding_box(page(), target()) :: %{String.t() => number()}
    def bounding_box(page, target) do
      {:ok, element} =
        Frame.wait_for_selector(
          page.frame,
          page.opts ++ [selector: to_selector(target, nil), state: "visible"]
        )

      %{result: %{value: box}} =
        Connection.send(
          page.opts[:connection],
          %{guid: element.guid, method: :bounding_box, params: %{}},
          page.opts[:timeout]
        )

      Map.new(box, fn {key, value} -> {to_string(key), value} end)
    end

    @doc "The window's accessibility tree in Playwright's ARIA snapshot format."
    @spec aria_snapshot(page()) :: String.t()
    def aria_snapshot(page) do
      %{result: %{snapshot: snapshot}} = send_frame(page, :aria_snapshot, %{})
      snapshot
    end

    @doc "The accessible names of every button in the window, in order."
    @spec buttons(page()) :: [String.t()]
    def buttons(page) do
      for [_, name] <- Regex.scan(~r/- button "((?:[^"\\]|\\.)*)"/, aria_snapshot(page)),
          do: String.replace(name, ~S(\"), ~s("))
    end

    @doc "The window as PNG bytes."
    @spec screenshot(page()) :: binary()
    def screenshot(page) do
      {:ok, base64} = Page.screenshot(page.page, page.opts)
      Base.decode64!(base64)
    end

    @doc "Resizes the window's content area to `width` x `height` pixels."
    @spec resize(page(), pos_integer(), pos_integer()) :: :ok
    def resize(page, width, height) do
      %{} =
        Connection.send(
          page.opts[:connection],
          %{
            guid: page.page,
            method: :set_viewport_size,
            params: %{viewport_size: %{width: width, height: height}}
          },
          page.opts[:timeout]
        )

      :ok
    end

    ## Internals

    defp act(page, action, target, role, params \\ []) do
      opts = page.opts ++ [selector: to_selector(target, role), strict: true] ++ params

      case apply(Frame, action, [page.frame, opts]) do
        {:ok, _} -> :ok
        {:error, error} -> raise "#{action} #{inspect(target)} failed: #{inspect(error)}"
      end
    end

    defp read(page, action, target, role, params \\ []) do
      opts = page.opts ++ [selector: to_selector(target, role), strict: true] ++ params

      case apply(Frame, action, [page.frame, opts]) do
        {:ok, value} -> value
        {:error, error} -> raise "#{action} #{inspect(target)} failed: #{inspect(error)}"
      end
    end

    defp to_selector(name, nil) when is_binary(name), do: selector(label: name)
    defp to_selector(name, role) when is_binary(name), do: selector(role: role, name: name)
    defp to_selector(opts, _role) when is_list(opts), do: selector(opts)

    defp send_frame(page, method, params),
      do:
        Connection.send(
          page.opts[:connection],
          %{guid: page.frame, method: method, params: params},
          page.opts[:timeout]
        )

    defp await_endpoint!(file, os_pid, timeout) when timeout <= 0 do
      System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
      raise "the app did not start gpui-playwright (no endpoint in #{file})"
    end

    defp await_endpoint!(file, os_pid, timeout) do
      case File.read(file) do
        {:ok, "ws://" <> _ = endpoint} ->
          String.trim(endpoint)

        _ ->
          Process.sleep(100)
          await_endpoint!(file, os_pid, timeout - 100)
      end
    end

    defp await_exit(os_pid, 0) do
      System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
      :ok
    end

    defp await_exit(os_pid, tries) do
      case System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true) do
        {_, 0} ->
          Process.sleep(100)
          await_exit(os_pid, tries - 1)

        _ ->
          :ok
      end
    end

    defp collect_log(os_port, acc) do
      receive do
        {^os_port, {:data, data}} -> collect_log(os_port, [acc, data])
      after
        0 -> IO.iodata_to_binary(acc)
      end
    end
  end
end
