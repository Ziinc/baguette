defmodule Baguette.Window do
  @moduledoc """
  The app's native windows. Window `0` is the main one; a view renders to
  the window its `:window` option names.
  """

  @type info :: %{
          title: String.t() | nil,
          x: number() | nil,
          y: number() | nil,
          width: number(),
          height: number()
        }

  @doc "Opens window `window` (options: `:title`, `:width`, `:height`)."
  @spec open(non_neg_integer(), keyword()) :: :ok
  def open(window, opts \\ []) do
    call("window.open", window, Map.new(Keyword.take(opts, [:title, :width, :height])))
  end

  @doc "Closes window `window`."
  @spec close(non_neg_integer()) :: :ok
  def close(window), do: call("window.close", window, %{})

  @spec set_title(non_neg_integer(), String.t()) :: :ok
  def set_title(window, title) when is_binary(title),
    do: call("window.set_title", window, %{title: title})

  @doc "Moves or resizes `window`: any of `:x`, `:y`, `:width` and `:height`, in logical pixels."
  @spec set_bounds(non_neg_integer(), keyword()) :: :ok
  def set_bounds(window, bounds),
    do:
      call("window.set_bounds", window, Map.new(Keyword.take(bounds, [:x, :y, :width, :height])))

  @doc "The title and bounds of `window`, or `nil` when it isn't open."
  @spec info(non_neg_integer()) :: info() | nil
  def info(window) do
    case Baguette.Host.call("window.info", %{window: window}) do
      nil -> nil
      info -> Map.new(~w(title x y width height), &{String.to_atom(&1), info[&1]})
    end
  end

  defp call(name, window, args) do
    Baguette.Host.call(name, Map.put(args, :window, window))
    :ok
  end
end
