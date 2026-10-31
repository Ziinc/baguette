defmodule Baguette.Release.Slim.Fake do
  @moduledoc false
  # Fake release layouts for tests, built from Erlang sources so that
  # nothing is loaded into the test VM.

  @doc """
  Writes `root/lib/<app>-0.1.0/ebin` with a module per `{name, body}` in
  `modules` (Erlang forms after the `-module` line) and an `.app` file with
  `props`. Returns the ebin path.
  """
  def app(root, app, modules, props \\ []) do
    ebin = Path.join([root, "lib", "#{app}-0.1.0", "ebin"])
    File.mkdir_p!(ebin)

    names =
      for {name, body} <- modules,
          do:
            (
              beam!(ebin, name, body)
              name
            )

    spec = {:application, app, [vsn: ~c"0.1.0", modules: names] ++ props}
    File.write!(Path.join(ebin, "#{app}.app"), :io_lib.format(~c"~p.~n", [spec]))
    ebin
  end

  @doc "Compiles one Erlang module into `dir`."
  def beam!(dir, name, body) do
    source = "-module('#{name}').\n-compile([export_all, nowarn_export_all]).\n#{body}\n"
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source))
    forms = split(tokens, [], []) |> Enum.map(&elem(:erl_parse.parse_form(&1), 1))
    {:ok, ^name, binary} = :compile.forms(forms, [:binary])
    File.write!(Path.join(dir, "#{name}.beam"), binary)
  end

  defp split([], [], acc), do: Enum.reverse(acc)

  defp split([{:dot, _} = dot | rest], form, acc),
    do: split(rest, [], [Enum.reverse([dot | form]) | acc])

  defp split([token | rest], form, acc), do: split(rest, [token | form], acc)
end
