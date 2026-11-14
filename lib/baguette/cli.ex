defmodule Baguette.CLI do
  @moduledoc """
  The command line the app was started with.

  Declare the interface in the release's options (`cli:` in
  `Baguette.Release`, which takes Tauri's CLI plugin schema); the host parses
  `argv` and the app reads the result:

      case Baguette.CLI.matches() do
        {:ok, %Baguette.CLI{subcommand: {"sum", %{args: %{"a" => a, "b" => b}}}}} ->
          IO.puts(String.to_integer(a) + String.to_integer(b))
          Baguette.App.exit(0)

        {:ok, %Baguette.CLI{args: %{"help" => help}}} when is_binary(help) ->
          IO.puts(help)
          Baguette.App.exit(0)

        {:ok, _no_subcommand} ->
          :open_the_window

        {:error, _reason} ->
          :open_the_window
      end

  `args` maps each declared argument's name to its value: `true` or `false`
  for a flag, a string for an option or positional, a list of strings for one
  that takes several, `nil` when absent. `occurrences` maps the same names to
  how many times each was given. `subcommand` is `nil`, or `{name, %CLI{}}`
  with the subcommand's own arguments (and its own subcommand, if it has
  one).

  `--help` is a successful match, not an exit: the help text is
  `args["help"]`. Print it with
  `IO.puts/1`, then `Baguette.App.exit/1`.

  ## Running as a command

  When the release declares a `cli`, the host opens no window until the app
  first renders to window 0. A run that never renders (a command that prints
  and exits) is headless and must end with `Baguette.App.exit/1`: nothing else
  ends it. Print with `IO.puts/1` before exiting. A view must not be started
  for such a run, or it opens the window. On Linux even a headless run needs
  a display (X, Wayland or `xvfb-run`): Tauri initialises GTK at startup.

  Desktop only. On Android and iOS `matches/0` returns the "declares no cli"
  error. Without a native host (`Baguette.Test`) it returns what
  `Baguette.Test.put_cli/2` set.
  """

  defstruct args: %{}, occurrences: %{}, subcommand: nil

  @type t :: %__MODULE__{
          args: %{String.t() => term()},
          occurrences: %{String.t() => non_neg_integer()},
          subcommand: nil | {String.t(), t()}
        }

  @doc """
  The parsed command line, or `{:error, reason}` when the release declares no
  `cli` or the arguments do not fit it (`reason` is the host's message, such
  as clap's "unexpected argument"). Arguments are the process's own: the
  host parses them before the app starts.
  """
  @spec matches() :: {:ok, t()} | {:error, String.t()}
  def matches do
    case Baguette.Host.call("cli.matches", %{}, :errors) do
      {:ok, %{} = wire} -> {:ok, from_wire(wire)}
      {:ok, _} -> {:error, "the host returned no matches"}
      {:error, "cli.matches: " <> reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec from_wire(map()) :: t()
  def from_wire(%{"args" => args} = wire) do
    %__MODULE__{
      args: Map.new(args, fn {name, arg} -> {name, arg["value"]} end),
      occurrences: Map.new(args, fn {name, arg} -> {name, arg["occurrences"] || 0} end),
      subcommand:
        case wire["subcommand"] do
          %{"name" => name, "matches" => matches} -> {name, from_wire(matches)}
          _ -> nil
        end
    }
  end
end
