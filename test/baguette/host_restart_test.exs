defmodule Baguette.HostRestartTest do
  # Restarts Baguette.Host, so runs alone.
  use ExUnit.Case, async: false
  alias Baguette.Host

  test "a window has one owner" do
    window = System.unique_integer([:positive])
    assert Host.own(window) == :ok
    assert Host.own(window) == :ok

    other = Task.async(fn -> Host.own(window) end)
    assert Task.await(other) == {:error, {:already_owned, self()}}
  end

  test "owners outlive a restart of the host process" do
    window = System.unique_integer([:positive])
    :ok = Host.own(window)
    host = Process.whereis(Host)
    ref = Process.monitor(host)
    Process.exit(host, :kill)
    assert_receive {:DOWN, ^ref, :process, ^host, :killed}

    wait_for_restart(host)
    Host.dispatch(%{"type" => "click", "window" => window, "event" => "inc"})
    assert_receive {:baguette_event, %{"event" => "inc"}}
  end

  defp wait_for_restart(old) do
    case Process.whereis(Host) do
      pid when is_pid(pid) and pid != old ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_restart(old)
    end
  end
end
