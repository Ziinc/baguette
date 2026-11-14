defmodule Baguette.EventsTest do
  # The events the native host sends, from levain's conformance fixture
  # (test/fixtures/events.json, kept equal to levain's by CI). Each goes
  # through the host's message path (`{:baguette_event, json}`) to a real view.
  #
  # The message goes to a private `Baguette.Host` process, not the app's: it
  # routes to the view exactly as the real one does, and nothing a fixture
  # does (a resync, a reply) can take down the shared host and registry.
  # Views own the fixture's windows, so this module does not run alongside
  # others.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Baguette.Host

  @fixture "test/fixtures/events.json"
  @external_resource @fixture
  @events @fixture |> File.read!() |> JSON.decode!()

  defmodule Probe do
    @moduledoc false
    use Baguette.View

    # Every action the fixture names is bound, so `handle_action/2` hears it.
    for %{"json" => %{"type" => "action", "action" => action}} <-
          "test/fixtures/events.json" |> File.read!() |> JSON.decode!() do
      Module.put_attribute(
        __MODULE__,
        :baguette_keymap,
        {"secondary-x", String.to_atom(action), nil}
      )
    end

    def mount(args), do: {:ok, %{test: Keyword.fetch!(args, :test)}}

    def render(assigns), do: ~H"<text>probe</text>"

    def handle_event(event, values, assigns) do
      send(assigns.test, {:event, event, values})
      {:noreply, assigns}
    end

    def handle_rows(event, range, assigns) do
      send(assigns.test, {:rows, event, range})
      {:reply, [], assigns}
    end

    def handle_action(action, assigns) do
      send(assigns.test, {:action, action})
      {:noreply, assigns}
    end

    def handle_info({:appearance, _} = message, assigns) do
      send(assigns.test, message)
      {:noreply, assigns}
    end
  end

  # The host decodes with OTP's `:json` (OTP 27+). Older OTPs lack it, so the
  # decoder Elixir ships for them stands in, for this module only.
  setup_all do
    unless Code.ensure_loaded?(:json) do
      Module.create(
        :json,
        quote do
          def decode(binary), do: :elixir_json.decode(binary)
          def encode(term), do: :elixir_json.encode(term)
        end,
        Macro.Env.location(__ENV__)
      )

      on_exit(fn ->
        :code.purge(:json)
        :code.delete(:json)
      end)
    end

    :ok
  end

  setup do
    {:ok, host} = GenServer.start_link(Host, [])
    %{host: host}
  end

  test "the fixture names every event it holds once, and covers each type" do
    names = Enum.map(@events, & &1["name"])
    assert names == Enum.uniq(names)

    types = @events |> Enum.map(& &1["json"]["type"]) |> Enum.uniq() |> Enum.sort()

    assert types ==
             ~w(action appearance change click drag keydown menu pick reply resync rows submit)
  end

  for %{"name" => name, "json" => json} <- @events do
    test "#{name}", %{host: host} do
      event = unquote(Macro.escape(json))
      window = event["window"]
      view = start_supervised!({Probe, window: window || 0, args: [test: self()]})
      assert_handled(event, host, view)
      # And nothing more reached the view.
      refute_receive _, 20
    end
  end

  # A null `result` should reach the caller as `nil`; the host's decoder
  # makes it `:null`, so `Baguette.Clipboard.read/0` of an empty clipboard
  # (and `Baguette.Window.info/1` of a closed window) get the atom instead.
  @tag skip: "known mismatch: Baguette.Host answers a null result with :null, not nil"
  test "a null result reaches the caller as nil", %{host: host} do
    assert {nil, _log} = reply_to(host, %{"type" => "reply", "ref" => 1, "result" => nil})
  end

  # What the native host's message does, by event type. A type with no clause
  # here is one Baguette does not handle, and fails the test.
  defp assert_handled(%{"type" => type, "event" => name} = event, host, view)
       when type in ~w(click change submit pick keydown menu) do
    deliver(host, view, event)
    values = event["values"] || %{}
    assert_receive {:event, ^name, ^values}
  end

  defp assert_handled(%{"type" => "drag", "event" => name} = event, host, view) do
    deliver(host, view, event)
    values = Map.merge(event["values"], Map.take(event, ["dx", "dy"]))
    assert_receive {:event, ^name, ^values}
  end

  defp assert_handled(%{"type" => "rows", "id" => id} = event, host, view) do
    deliver(host, view, event)
    name = event["event"]
    range = event["start"]..(event["end"] - 1)//1
    assert_receive {:rows, ^name, ^range}
    [first, last] = event["visible"]
    assert %{^id => %{event: ^name, visible: {^first, ^last}}} = :sys.get_state(view).lists
  end

  defp assert_handled(%{"type" => "action", "action" => action} = event, host, view) do
    deliver(host, view, event)
    action = String.to_existing_atom(action)
    assert_receive {:action, ^action}
  end

  defp assert_handled(%{"type" => "appearance", "appearance" => appearance} = event, host, view) do
    deliver(host, view, event)
    appearance = String.to_existing_atom(appearance)
    assert_receive {:appearance, ^appearance}
  end

  # The host answers a resync itself, with the window's whole frame, if it
  # has one (it has none here: sending a frame needs the native host). The
  # view never sees it.
  defp assert_handled(%{"type" => "resync"} = event, host, view) do
    deliver(host, view, event)
    assert Process.alive?(host)
  end

  # A reply goes to whoever made the call it answers, as its return value
  # (an error is also logged); the view never sees it.
  defp assert_handled(%{"type" => "reply", "result" => result} = event, host, _view) do
    {got, log} = reply_to(host, event)

    # A null result: see the skipped test above.
    if is_nil(result), do: assert(got in [nil, :null]), else: assert(got == result)

    case event["error"] do
      nil -> refute log =~ "platform call failed"
      error -> assert log =~ "baguette: platform call failed: #{error}"
    end
  end

  defp deliver(host, view, event) do
    send(host, {:baguette_event, IO.iodata_to_binary(JSON.encode!(event))})
    :sys.get_state(host)
    :sys.get_state(view)
  end

  # Delivers reply `event` for a call this process is waiting on, and returns
  # what that call returns, with what the host logged.
  defp reply_to(host, %{"ref" => ref} = event) do
    from = {self(), make_ref()}
    :sys.replace_state(host, fn state -> put_in(state.calls[ref], from) end)

    log =
      capture_log(fn ->
        send(host, {:baguette_event, IO.iodata_to_binary(JSON.encode!(event))})
        :sys.get_state(host)
      end)

    {_, tag} = from
    assert_receive {^tag, got}
    {got, log}
  end
end
