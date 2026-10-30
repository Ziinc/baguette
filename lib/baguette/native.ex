defmodule Baguette.Native do
  @moduledoc false
  # The NIF that talks to the native host (`native/baguette_nif`).

  use Rustler, otp_app: :baguette, crate: "baguette_nif", path: "native/baguette_nif"

  @spec attach(non_neg_integer(), binary()) :: :ok | {:error, atom()}
  def attach(_host_address, _components_json), do: :erlang.nif_error(:nif_not_loaded)

  @spec render(non_neg_integer(), binary()) :: :ok
  def render(_window, _json), do: :erlang.nif_error(:nif_not_loaded)
end
