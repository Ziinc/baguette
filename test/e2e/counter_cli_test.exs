defmodule Baguette.E2E.CounterCLITest do
  # The counter release run as a command: `counter_app sum 2 3` prints 5 and
  # exits 0 without opening a window. Build it first, as
  # counter_playwright_test.exs says, then run `mix test --only playwright`
  # under a display (a headless run still needs one on Linux: Tauri
  # initialises GTK).
  use ExUnit.Case, async: false

  @moduletag :playwright

  @app Path.expand("../../examples/counter/_build/prod/rel/counter/bin/counter_app", __DIR__)

  # Runs the release with `args`; returns `{stdout, stderr, exit_status}`.
  # Stderr goes to a file, to read it apart from stdout. A run that does not
  # end by itself fails the test.
  defp run(args) do
    err = Path.join(System.tmp_dir!(), "baguette-cli-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(err) end)

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", ~s(exec "$0" "$@" 2>"$ERR_FILE"), @app | args],
          env: [{"ERR_FILE", err}]
        )
      end)

    case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {stdout, status}} -> {stdout, File.read!(err), status}
      _ -> flunk("`counter_app #{Enum.join(args, " ")}` did not exit within 60 s")
    end
  end

  test "sum prints the sum and exits 0, without a window" do
    {stdout, log, status} = run(["sum", "2", "3"])

    assert stdout == "5\n"
    assert status == 0
    # Nothing rendered, so the host never opened a window.
    refute log =~ "levain: first frame"
  end

  test "a bad number is an error on stderr and exit 2" do
    {stdout, log, status} = run(["sum", "two", "3"])

    assert stdout == ""
    assert log =~ "not a number: two"
    assert status == 2
    refute log =~ "levain: first frame"
  end
end
