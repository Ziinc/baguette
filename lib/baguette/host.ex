defmodule Baguette.Host do
  @moduledoc """
  The connection to the native host.

  When the BEAM runs inside Baguette's host, the host passes the address of
  its API as `-baguette_host <address>`, and this process attaches the NIF to
  it. Renders then go to native windows and UI events come back here, to be
  routed to the view that owns the window.

  Without a host (`mix test`, `iex -S mix`), the host is *headless*: renders
  are kept in memory, so `Baguette.Test` can read them and dispatch events.
  """
  use GenServer
  require Logger

  @type window :: non_neg_integer()

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether a native host is attached."
  @spec native?() :: boolean()
  def native?, do: GenServer.call(__MODULE__, :native?)

  @doc "Sends `frame` (`%{theme: map, root: node}`) to `window`."
  @spec render(window(), map()) :: :ok
  def render(window, frame), do: GenServer.cast(__MODULE__, {:render, window, frame})

  @doc "The last frame rendered to `window`, or `nil`."
  @spec last_frame(window()) :: map() | nil
  def last_frame(window), do: GenServer.call(__MODULE__, {:last_frame, window})

  @doc "Makes the calling process the owner of `window`'s events."
  @spec own(window()) :: :ok
  def own(window), do: GenServer.call(__MODULE__, {:own, window, self()})

  @doc false
  # Headless text entry: what was typed into the input at `path`, and the
  # `value` the view had rendered for it then. The typed text stands until
  # the view renders a different value, as in a native input.
  def type(window, path, text, rendered),
    do: GenServer.call(__MODULE__, {:type, window, path, text, rendered})

  @doc false
  def typed(window), do: GenServer.call(__MODULE__, {:typed, window})

  @doc "The process that owns `window`'s events, or `nil`."
  @spec owner(window()) :: pid() | nil
  def owner(window), do: GenServer.call(__MODULE__, {:owner, window})

  @doc "Delivers `event` as if the native host had sent it."
  @spec dispatch(map()) :: :ok
  def dispatch(event), do: GenServer.cast(__MODULE__, {:event, event})

  @impl true
  def init(_opts) do
    native =
      case :init.get_argument(:baguette_host) do
        {:ok, [[address]]} ->
          attach!(List.to_integer(address))
          true

        _ ->
          false
      end

    {:ok, %{native: native, owners: %{}, frames: %{}, typed: %{}}}
  end

  # The host refuses component sets compiled from other manifests than its
  # own, and says so in the window.
  defp attach!(address) do
    components = JSON.encode!(Baguette.Components.compiled())

    case Baguette.Native.attach(address, components) do
      :ok ->
        :ok

      {:error, :components_mismatch} ->
        raise "the native host's component sets differ from the manifests " <>
                "this release was compiled against; rebuild the release"
    end
  end

  @impl true
  def handle_call(:native?, _from, state), do: {:reply, state.native, state}

  def handle_call({:last_frame, window}, _from, state),
    do: {:reply, Map.get(state.frames, window), state}

  def handle_call({:type, window, path, text, rendered}, _from, state),
    do: {:reply, :ok, put_in(state.typed[{window, path}], {text, rendered})}

  def handle_call({:typed, window}, _from, state) do
    typed = for {{^window, path}, entry} <- state.typed, into: %{}, do: {path, entry}
    {:reply, typed, state}
  end

  def handle_call({:owner, window}, _from, state),
    do: {:reply, Map.get(state.owners, window), state}

  def handle_call({:own, window, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, put_in(state.owners[window], pid)}
  end

  @impl true
  def handle_cast({:render, window, frame}, state) do
    if state.native, do: Baguette.Native.render(window, IO.iodata_to_binary(:json.encode(frame)))
    state = put_in(state.frames[window], frame)
    {:noreply, %{state | typed: settle_typed(state.typed, window, frame)}}
  end

  def handle_cast({:event, event}, state) do
    route(event, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:baguette_event, json}, state) do
    route(:json.decode(json), state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    owners = for {window, owner} <- state.owners, owner != pid, into: %{}, do: {window, owner}
    {:noreply, %{state | owners: owners}}
  end

  # A frame that renders a different `value` for an input replaces what was
  # typed into it, as the native host does.
  defp settle_typed(typed, window, frame) do
    Map.reject(typed, fn
      {{^window, path}, {_text, rendered}} -> rendered_value(frame["root"], path) != rendered
      _ -> false
    end)
  end

  defp rendered_value(root, "root" <> rest) do
    rest
    |> String.split(".", trim: true)
    |> Enum.reduce(root, fn
      i, %{"c" => children} -> Enum.at(children, String.to_integer(i))
      _i, _ -> nil
    end)
    |> case do
      %{"a" => attrs} -> attrs["value"] || ""
      _ -> nil
    end
  end

  defp route(%{"window" => window} = event, state) do
    case state.owners do
      %{^window => pid} -> send(pid, {:baguette_event, event})
      _ -> Logger.debug("baguette: event for unowned window #{window}")
    end
  end
end
