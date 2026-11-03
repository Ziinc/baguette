defmodule IosNifDemoC do
  @moduledoc "An elixir_make NIF in C, for the iOS dependency-NIF test."
  @on_load :load

  def load do
    :erlang.load_nif(:filename.join(:code.priv_dir(:ios_nif_demo_c), ~c"ios_nif_demo_c"), 0)
  end

  def mul(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
end
