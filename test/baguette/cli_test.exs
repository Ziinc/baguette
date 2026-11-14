defmodule Baguette.CLITest do
  # `Baguette.CLI.matches/0` and `Baguette.App.exit/1` against the headless
  # host, and the fixture's replies read as the native host sends them.
  use ExUnit.Case, async: false

  alias Baguette.{App, CLI, Host}

  @events "test/fixtures/events.json"
          |> File.read!()
          |> JSON.decode!()
  @replies for %{"build" => "reply_cli_matches", "json" => json} = e <- @events, do: {e, json}

  setup do
    Host.reset_platform()
    on_exit(&Host.reset_platform/0)
  end

  test "without a declared cli, matches/0 is an error" do
    assert CLI.matches() == {:error, "the app declares no cli"}
  end

  test "matches/0 returns the values, the occurrences and the subcommand" do
    Baguette.Test.put_cli(%{"verbose" => true, "quiet" => false}, {"sum", %{"a" => "2"}})

    assert {:ok,
            %CLI{
              args: %{"verbose" => true, "quiet" => false},
              occurrences: %{"verbose" => 1, "quiet" => 0},
              subcommand: {"sum", %CLI{args: %{"a" => "2"}, occurrences: %{"a" => 1}}}
            }} = CLI.matches()
  end

  test "subcommands nest" do
    Baguette.Test.put_cli(%{}, {"remote", %{}, {"add", %{"url" => "u"}}})

    assert {:ok,
            %CLI{subcommand: {"remote", %CLI{subcommand: {"add", %CLI{args: %{"url" => "u"}}}}}}} =
             CLI.matches()
  end

  test "--help is a match whose help text is args[\"help\"]" do
    Baguette.Test.put_cli(%{"help" => "Usage: app"})
    assert {:ok, %CLI{args: %{"help" => "Usage: app"}}} = CLI.matches()
  end

  test "exit/1 records the code and leaves the VM running" do
    assert Baguette.Test.exit_code() == nil
    assert App.exit(2) == :ok
    assert Baguette.Test.exit_code() == 2
    assert App.exit() == :ok
    assert Baguette.Test.exit_code() == 0
  end

  test "reset_platform/0 clears the cli and the exit code" do
    Baguette.Test.put_cli(%{"a" => "1"})
    App.exit(3)
    Host.reset_platform()
    assert {:error, _} = CLI.matches()
    assert Baguette.Test.exit_code() == nil
  end

  describe "the native host's replies" do
    test "the fixture has success and error replies" do
      assert Enum.any?(@replies, fn {_, j} -> j["error"] end)
      assert Enum.any?(@replies, fn {_, j} -> j["result"] end)
    end

    for {%{"name" => name}, %{"result" => %{} = result}} <- @replies do
      test "#{name} reads as a %Baguette.CLI{}" do
        result = unquote(Macro.escape(result))
        cli = CLI.from_wire(result)

        for {arg, %{"value" => value, "occurrences" => n}} <- result["args"] do
          assert cli.args[arg] == value
          assert cli.occurrences[arg] == n
        end

        case result["subcommand"] do
          nil -> assert cli.subcommand == nil
          %{"name" => sub} -> assert {^sub, %CLI{}} = cli.subcommand
        end
      end
    end
  end
end
