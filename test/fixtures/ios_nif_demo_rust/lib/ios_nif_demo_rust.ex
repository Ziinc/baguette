defmodule IosNifDemoRust do
  @moduledoc "A Rustler NIF, for the iOS dependency-NIF test."
  use Rustler, otp_app: :ios_nif_demo_rust, crate: "ios_nif_demo_rust"

  def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
end
