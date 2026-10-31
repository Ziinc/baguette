defmodule Baguette.Native do
  @moduledoc false
  # The NIF that talks to the native host (`native/baguette_nif`).

  # Precompiled unless built from source; see Baguette.Native.Precompiled.
  use RustlerPrecompiled,
    otp_app: :baguette,
    crate: "baguette_nif",
    path: "native/baguette_nif",
    base_url: Baguette.Native.Precompiled.base_url(),
    version: Mix.Project.config()[:version],
    targets: Baguette.Native.Precompiled.targets(),
    force_build: Baguette.Native.Precompiled.force_build?()

  @spec attach(non_neg_integer(), binary()) :: :ok | {:error, atom()}
  def attach(_host_address, _components_json), do: :erlang.nif_error(:nif_not_loaded)

  @spec call(binary()) :: :ok
  def call(_json), do: :erlang.nif_error(:nif_not_loaded)

  @spec render(non_neg_integer(), binary()) :: :ok
  def render(_window, _json), do: :erlang.nif_error(:nif_not_loaded)
end
