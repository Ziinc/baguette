defmodule Counter.CLI do
  @moduledoc """
  The counter as a command: `counter_app sum 2 3` prints `5` and exits with
  no window. With no subcommand it is the counter window, as ever.

  The command line is declared in `mix.exs` (`baguette: [cli: ...]`).
  """

  @type plan :: :window | {:stdout | :stderr, String.t(), integer()}

  @doc "What this run does, from `Baguette.CLI.matches/0`: open the window, or print and exit."
  @spec plan({:ok, Baguette.CLI.t()} | {:error, String.t()}) :: plan()
  def plan({:error, "the app declares no cli"}), do: :window
  def plan({:error, reason}), do: {:stderr, reason, 2}

  def plan({:ok, %Baguette.CLI{args: %{"help" => help}}}) when is_binary(help),
    do: {:stdout, help, 0}

  def plan({:ok, %Baguette.CLI{subcommand: {"sum", %Baguette.CLI{args: %{"help" => help}}}}})
      when is_binary(help),
      do: {:stdout, help, 0}

  def plan({:ok, %Baguette.CLI{subcommand: {"sum", %Baguette.CLI{args: %{"a" => a, "b" => b}}}}}) do
    with {:ok, a} <- number(a),
         {:ok, b} <- number(b) do
      {:stdout, Integer.to_string(a + b), 0}
    else
      {:error, text} -> {:stderr, "not a number: #{text}", 2}
    end
  end

  def plan({:ok, _no_subcommand}), do: :window

  @doc """
  Prints what `plan/1` says and ends the app: a run that never renders has
  no window, and `Baguette.App.exit/1` is what stops it.
  """
  @spec run(plan()) :: :ok
  def run({:stdout, text, code}), do: finish(:stdio, text, code)
  def run({:stderr, text, code}), do: finish(:stderr, text, code)

  defp finish(device, text, code) do
    IO.puts(device, text)
    Baguette.App.exit(code)
  end

  defp number(text) do
    case Integer.parse(to_string(text)) do
      {n, ""} -> {:ok, n}
      _ -> {:error, text}
    end
  end
end
