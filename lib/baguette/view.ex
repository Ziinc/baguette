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

  ## Long lists

  `<list id="jobs" rows={@count} phx-rows="jobs" class="h-96" />` is a
  virtualized list (GPUI's `uniform_list`): the host draws only the rows on
  screen and asks for them by range. `handle_rows/3` renders them:

      def handle_rows("jobs", range, assigns) do
        rows = for job <- Jobs.slice(range), do: row(%{job: job})
        {:reply, rows, assigns}
      end

  Every row has the height of the first one the host measures; until a row
  arrives it is `row-height` pixels tall (default 24). Each render of the
  view renders the rows on screen again, so they follow the assigns like
  the rest of the template. `id` names the list; it must be unique in the
  window.

  ## Keymaps and focus

      keymap "secondary-k", :open_palette, context: "Jobs"
      keymap "escape", :close

      def handle_action(:open_palette, assigns), do: {:noreply, %{assigns | palette: true}}

  binds keystrokes (GPUI's syntax: `secondary-` is Cmd on macOS and Ctrl
  elsewhere) to actions, which `handle_action/2` receives. A binding with a
  `context:` fires only while focus is inside an element with that
  `key-context`. An element with `tabindex="N"` takes focus when clicked,
  and Tab and Shift-Tab move focus in `tabindex` order.

  Start it in your supervision tree with
  `{MyApp.CounterView, theme: MyApp.Theme}`. Templates are HEEx, with
  function components and `phx-click`/`phx-value-*` bindings as in Phoenix
  LiveView.
  """

  @type assigns :: map()

  @callback mount(args :: term()) :: {:ok, assigns()}
  @callback render(assigns()) :: Phoenix.LiveView.Rendered.t()
  @callback handle_event(event :: String.t(), values :: map(), assigns()) :: {:noreply, assigns()}
  @callback handle_info(msg :: term(), assigns()) :: {:noreply, assigns()}
  @callback handle_rows(event :: String.t(), Range.t(), assigns()) ::
              {:reply, [Phoenix.LiveView.Rendered.t()], assigns()}
  @callback handle_action(action :: atom(), assigns()) :: {:noreply, assigns()}
  @optional_callbacks handle_event: 3, handle_info: 2, handle_rows: 3, handle_action: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour Baguette.View
      # Function components (`attr`, `slot`) can live next to the view.
      use Phoenix.Component
      import Baguette.View, only: [keymap: 2, keymap: 3]
      Module.register_attribute(__MODULE__, :baguette_keymap, accumulate: true)
      @before_compile Baguette.View

      def child_spec(opts) do
        %{
          id: {__MODULE__, Keyword.get(opts, :window, 0)},
          start: {Baguette.View, :start_link, [__MODULE__, opts]}
        }
      end
    end
  end

  @doc """
  Binds `keys` to `action` while focus is in `context:` (any `key-context`
  attribute), or anywhere without one. See "Keymaps and focus".
  """
  defmacro keymap(keys, action, opts \\ []) when is_binary(keys) and is_atom(action) do
    quote do
      @baguette_keymap {unquote(keys), unquote(action), unquote(opts[:context])}
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      @doc false
      def __keymap__, do: Enum.reverse(@baguette_keymap)
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
    state = %{module: module, window: window, theme: theme, assigns: assigns, lists: %{}}
    {:ok, push(state)}
  end

  @impl GenServer
  def handle_info({:baguette_event, %{"type" => type} = event}, state)
      when type in ["click", "change", "submit", "pick", "keydown", "menu"] do
    callback(state, :handle_event, [event["event"], event["values"] || %{}, state.assigns])
  end

  # A drag reports where it ended relative to where it started, in pixels.
  def handle_info({:baguette_event, %{"type" => "drag"} = event}, state) do
    values = Map.merge(event["values"] || %{}, Map.take(event, ["dx", "dy"]))
    callback(state, :handle_event, [event["event"], values, state.assigns])
  end

  # The host shows rows `start` to `end` (exclusive) of a list and lacks
  # them; it keeps `visible` on screen, which every render refreshes.
  def handle_info({:baguette_event, %{"type" => "rows", "id" => id} = event}, state) do
    [first, last] = event["visible"] || [event["start"], event["end"]]
    state = put_in(state.lists[id], %{event: event["event"], visible: {first, last}})
    {rows, state} = rows(state, event["event"], event["start"], event["end"])
    Baguette.Host.rows(state.window, %{"id" => id, "start" => event["start"], "rows" => rows})
    {:noreply, state}
  end

  def handle_info({:baguette_event, %{"type" => "action", "action" => name}}, state) do
    case for {_keys, action, _context} <- state.module.__keymap__(),
             Atom.to_string(action) == name,
             do: action do
      [action | _] -> callback(state, :handle_action, [action, state.assigns])
      [] -> {:noreply, state}
    end
  end

  def handle_info({:baguette_event, %{"type" => "appearance", "appearance" => appearance}}, state) do
    appearance = if appearance == "dark", do: :dark, else: :light
    callback(state, :handle_info, [{:appearance, appearance}, state.assigns])
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
    {lists, rendered, state} = render_lists(state, list_counts(root, "root", %{}), %{}, %{})
    state = %{state | lists: Map.take(state.lists, Map.keys(rendered))}

    frame = %{
      "theme" => state.theme,
      "root" => root,
      "lists" => lists,
      "keymap" => keymap(state.module)
    }

    Baguette.Host.render(state.window, frame)
    state
  end

  defp keymap(module) do
    for {keys, action, context} <- module.__keymap__() do
      binding = %{"keys" => keys, "action" => Atom.to_string(action)}
      if context, do: Map.put(binding, "context", context), else: binding
    end
  end

  # Rows `first` to `last` (exclusive) as nodes, from handle_rows/3.
  defp rows(state, _event, first, last) when first >= last, do: {[], state}

  defp rows(state, event, first, last) do
    {:reply, rows, assigns} = state.module.handle_rows(event, first..(last - 1)//1, state.assigns)
    {Enum.map(rows, &Baguette.Tree.from_rendered/1), %{state | assigns: assigns}}
  end

  # Renders the on-screen rows of each list in `counts` that the host has
  # asked about, then those of the lists in these rows. Returns the rows by
  # list, every list found and the state.
  defp render_lists(state, counts, segments, found) do
    found = Map.merge(found, counts)

    {segments, nested, state} =
      Enum.reduce(counts, {segments, %{}, state}, fn {key, {count, path}},
                                                     {segments, nested, state} ->
        case state.lists do
          %{^key => %{event: event, visible: {first, last}}} ->
            {rows, state} = rows(state, event, first, min(last, count))

            nested =
              rows
              |> Enum.with_index(first)
              |> Enum.reduce(nested, fn {row, i}, acc ->
                list_counts(row, "#{path}.rows.#{i}", acc)
              end)

            {Map.put(segments, key, %{"start" => first, "rows" => rows}), nested, state}

          _ ->
            {segments, nested, state}
        end
      end)

    case Map.drop(nested, Map.keys(found)) do
      new when map_size(new) == 0 -> {segments, found, state}
      new -> render_lists(state, new, segments, found)
    end
  end

  # Each `<list>`'s row count and element path, by its key: its `id`, else
  # its path, numbered as the host numbers elements.
  defp list_counts(%{"t" => "list", "a" => attrs}, path, acc),
    do: Map.put(acc, attrs["id"] || path, {String.to_integer(attrs["rows"] || "0"), path})

  defp list_counts(%{"c" => children}, path, acc) do
    children
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {child, i}, acc -> list_counts(child, "#{path}.#{i}", acc) end)
  end

  defp list_counts(_node, _path, acc), do: acc
end
