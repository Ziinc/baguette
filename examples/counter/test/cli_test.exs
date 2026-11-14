defmodule Counter.CLITest do
  # The command line: `counter_app sum 2 3` prints 5 and exits without a
  # window; with no subcommand the app is the counter. Against the headless
  # host, where `Baguette.Test.put_cli/2` stands in for the parsed argv.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    Baguette.Host.reset_platform()
    on_exit(&Baguette.Host.reset_platform/0)
  end

  defp plan(args, subcommand) do
    Baguette.Test.put_cli(args, subcommand)
    Counter.CLI.plan(Baguette.CLI.matches())
  end

  describe "plan/1" do
    test "sum prints the sum and exits 0" do
      assert plan(%{}, {"sum", %{"a" => "2", "b" => "3"}}) == {:stdout, "5", 0}
      assert plan(%{}, {"sum", %{"a" => "-4", "b" => "10"}}) == {:stdout, "6", 0}
    end

    test "a bad number is an error on stderr, exit 2" do
      assert {:stderr, message, 2} = plan(%{}, {"sum", %{"a" => "two", "b" => "3"}})
      assert message =~ "two"
      assert {:stderr, _, 2} = plan(%{}, {"sum", %{"a" => "2", "b" => "3.5"}})
    end

    test "--help prints the help text, for the app and for a subcommand" do
      assert plan(%{"help" => "Usage: counter_app"}, nil) == {:stdout, "Usage: counter_app", 0}

      assert plan(%{}, {"sum", %{"help" => "Usage: sum"}}) == {:stdout, "Usage: sum", 0}
    end

    test "no subcommand, or no cli declared, is the counter window" do
      assert plan(%{}, nil) == :window
      Baguette.Host.reset_platform()
      assert Counter.CLI.plan(Baguette.CLI.matches()) == :window
    end

    test "arguments that do not parse are an error, exit 2" do
      assert Counter.CLI.plan({:error, "unexpected argument '--x'"}) ==
               {:stderr, "unexpected argument '--x'", 2}
    end
  end

  describe "run/1" do
    test "prints to stdout and exits with the code" do
      assert capture_io(fn -> Counter.CLI.run({:stdout, "5", 0}) end) == "5\n"
      assert Baguette.Test.exit_code() == 0
    end

    test "prints to stderr and exits with the code" do
      assert capture_io(:stderr, fn -> Counter.CLI.run({:stderr, "bad", 2}) end) == "bad\n"
      assert Baguette.Test.exit_code() == 2
    end
  end

  describe "the application's children" do
    test "start the view for the window" do
      children = Counter.Application.children(:window)
      assert {Counter.View, theme: Counter.Theme} in children
      assert Counter.Store in children
    end

    test "do not start the view for a command, which must not render" do
      children = Counter.Application.children({:stdout, "5", 0})
      refute Enum.any?(children, &match?({Counter.View, _}, &1))
      assert Counter.Store in children
      assert Enum.any?(children, &match?({Task, _}, &1))
    end
  end
end
