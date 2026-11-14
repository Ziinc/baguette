defmodule Baguette.App do
  @moduledoc """
  App-wide platform calls.

  A view hears the system switch between light and dark as
  `handle_info({:appearance, :light | :dark}, assigns)`.
  """

  @doc "Opens `url` with the system's handler for it (a browser, a mail client)."
  @spec open_url(String.t()) :: :ok
  def open_url(url) when is_binary(url) do
    Baguette.Host.call("app.open_url", %{url: url})
    :ok
  end

  @doc "Whether the system draws windows light or dark."
  @spec appearance() :: :light | :dark
  def appearance do
    case Baguette.Host.call("app.appearance", %{}) do
      "dark" -> :dark
      _ -> :light
    end
  end

  @doc """
  Ends the app with exit status `code` (default `0`).

  A command-line app that never renders (see `Baguette.CLI`) has no window,
  and nothing else ends it: it must finish with `exit/1`. Print first, with
  `IO.puts/1` (or `IO.puts(:stderr, ...)`): the process exits right after the
  host answers.

  Under `Baguette.Test`, the VM stays up and the code is recorded
  (`Baguette.Test.exit_code/0`).
  """
  @spec exit(integer()) :: :ok
  def exit(code \\ 0)
  def exit(0), do: finish(%{})
  def exit(code) when is_integer(code), do: finish(%{code: code})

  defp finish(args) do
    Baguette.Host.call("app.exit", args)
    :ok
  end
end
