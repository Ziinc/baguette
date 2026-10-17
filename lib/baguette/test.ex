defmodule Baguette.Test do
  @moduledoc """
  Helpers for testing views headlessly, the way a user would drive them.

      test "increments" do
        start_supervised!({MyApp.CounterView, window: 7})
        assert Baguette.Test.text(7) =~ "Count: 0"
        Baguette.Test.click(7, "Increment")
        assert Baguette.Test.text(7) =~ "Count: 1"
      end

  `click/2` finds the element by its `aria-label` or its text, as a screen
  reader would, and sends the same event the native host sends when it is
  clicked, so a test fails when the control is missing or not clickable.
  """

  alias Baguette.Host

  @doc "The root node last rendered to `window`."
  @spec tree(Host.window()) :: Baguette.Tree.tree() | nil
  def tree(window) do
    sync(window)
    with %{"root" => root} <- Host.last_frame(window), do: root
  end

  @doc "All text rendered to `window`, joined by spaces."
  @spec text(Host.window()) :: String.t()
  def text(window), do: window |> tree() |> texts() |> Enum.join(" ")

  @doc "Every element in `window` whose `aria-label` or text is `label`."
  @spec find_all(Host.window(), String.t()) :: [map()]
  def find_all(window, label),
    do: window |> tree() |> elements() |> Enum.filter(&labelled?(&1, label))

  @doc "Clicks the element labelled `label` in `window`."
  @spec click(Host.window(), String.t()) :: :ok
  def click(window, label) do
    clickable = for %{"a" => %{"phx-click" => _}} = el <- find_all(window, label), do: el

    case clickable do
      [%{"a" => attrs}] ->
        values =
          for {"phx-value-" <> key, value} <- attrs, into: %{}, do: {key, value}

        Host.dispatch(%{
          "type" => "click",
          "window" => window,
          "event" => attrs["phx-click"],
          "values" => values
        })

        sync(window)

      [] ->
        raise ArgumentError, "no clickable element labelled #{inspect(label)} in window #{window}"

      _ ->
        raise ArgumentError, "more than one clickable element labelled #{inspect(label)}"
    end
  end

  @manifest Path.expand("../../native/Cargo.toml", __DIR__)

  @doc """
  A PNG of what `window` last rendered, drawn offscreen by GPUI, for
  screenshot tests. Check it with gpui-visual-test's `cargo visual-test
  check`, or compare it with an approved image.

  Options: `:width` and `:height` in logical pixels (default 800x600). The
  image is at the headless renderer's scale (2x).

  Runs `$BAGUETTE_RENDER` when set, else builds and runs `baguette_render`
  (`baguette_view`'s `render` feature) with cargo. Needs GPUI's headless
  renderer: macOS, or Linux with Vulkan (lavapipe from `mesa-vulkan-drivers`
  without a GPU).
  """
  @spec render_png(Host.window(), keyword) :: binary
  def render_png(window, opts \\ []) do
    sync(window)
    frame = Host.last_frame(window) || raise ArgumentError, "nothing rendered to window #{window}"
    dir = Path.join(System.tmp_dir!(), "baguette_render_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      json = Path.join(dir, "frame.json")
      png = Path.join(dir, "frame.png")
      File.write!(json, JSON.encode!(frame))

      args =
        ["--frame", json, "--out", png] ++
          ["--width", to_string(opts[:width] || 800), "--height", to_string(opts[:height] || 600)]

      {cmd, args} =
        case System.get_env("BAGUETTE_RENDER") do
          nil ->
            {"cargo",
             ["run", "--quiet", "--manifest-path", @manifest, "-p", "baguette_view"] ++
               ["--features", "render", "--bin", "baguette_render", "--" | args]}

          bin ->
            {bin, args}
        end

      case System.cmd(cmd, args, stderr_to_stdout: true) do
        {_, 0} -> File.read!(png)
        {output, status} -> raise "baguette_render exited with #{status}:\n#{output}"
      end
    after
      File.rm_rf!(dir)
    end
  end

  # Waits until the owner of `window` has handled everything sent to it, and
  # the host has stored what it rendered in response.
  defp sync(window) do
    case Host.owner(window) do
      nil -> :ok
      pid -> :sys.get_state(pid)
    end

    :ok
  end

  defp elements(nil), do: []
  defp elements(text) when is_binary(text), do: []
  defp elements(%{"c" => children} = el), do: [el | Enum.flat_map(children, &elements/1)]

  defp texts(nil), do: []
  defp texts(text) when is_binary(text), do: [text]
  defp texts(%{"c" => children}), do: Enum.flat_map(children, &texts/1)

  defp labelled?(%{"a" => %{"aria-label" => label}}, label), do: true
  defp labelled?(el, label), do: el |> texts() |> Enum.join(" ") == label
end
