defmodule Baguette.View do
  @moduledoc """
  A native screen without LiveView: a process that owns a window's state and
  renders it with HEEx.

      defmodule MyApp.CounterView do
        use Baguette.View

        def mount(_args), do: {:ok, %{count: 0}}

        def render(assigns) do
          ~H\"\"\"
          <div class="flex-col gap-3 p-6">
            <text class="text-2xl">Count: {@count}</text>
            <button phx-click="inc">+</button>
          </div>
          \"\"\"
        end

        def handle_event("inc", _values, assigns), do: {:noreply, %{assigns | count: assigns.count + 1}}
      end

  Start it in your supervision tree with
  `{MyApp.CounterView, theme: MyApp.Theme}`. Templates use the same tags,
  classes, function components and `phx-click`/`phx-value-*` bindings as a
  `Baguette.LiveView`.
  """

  @type assigns :: map()

  @callback mount(args :: term()) :: {:ok, assigns()}
  @callback render(assigns()) :: Phoenix.LiveView.Rendered.t()
  @callback handle_event(event :: String.t(), values :: map(), assigns()) :: {:noreply, assigns()}
  @callback handle_info(msg :: term(), assigns()) :: {:noreply, assigns()}
  @optional_callbacks handle_event: 3, handle_info: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour Baguette.View
      import Phoenix.Component

      def child_spec(opts) do
        %{
          id: {__MODULE__, Keyword.get(opts, :window, 0)},
          start: {Baguette.View, :start_link, [__MODULE__, opts]}
        }
      end
    end
  end

  use GenServer

  @doc """
  Starts `module` as the view of a window.

  Options: `:window` (default `0`), `:theme` (a `Baguette.Theme` module) and
  `:args` (passed to `mount/1`).
  """
  def start_link(module, opts) do
    GenServer.start_link(__MODULE__, {module, opts})
  end

  @impl GenServer
  def init({module, opts}) do
    window = Keyword.get(opts, :window, 0)
    :ok = Baguette.Host.own(window)
    {:ok, assigns} = module.mount(Keyword.get(opts, :args, []))
    theme = if theme = opts[:theme], do: theme.tokens(), else: %{}
    state = %{module: module, window: window, theme: theme, assigns: assigns}
    {:ok, push(state)}
  end

  @impl GenServer
  def handle_info({:baguette_event, %{"type" => "click"} = event}, state) do
    callback(state, :handle_event, [event["event"], event["values"] || %{}, state.assigns])
  end

  def handle_info({:baguette_event, _event}, state), do: {:noreply, state}

  def handle_info(msg, state), do: callback(state, :handle_info, [msg, state.assigns])

  defp callback(state, name, args) do
    if function_exported?(state.module, name, length(args)) do
      {:noreply, assigns} = apply(state.module, name, args)
      {:noreply, push(%{state | assigns: assigns})}
    else
      {:noreply, state}
    end
  end

  defp push(state) do
    root = state.assigns |> state.module.render() |> Baguette.Tree.from_rendered()
    Baguette.Host.render(state.window, %{"theme" => state.theme, "root" => root})
    state
  end
end
