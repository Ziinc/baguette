defmodule Baguette.Native.Precompiled do
  @moduledoc false
  # Where Baguette's NIF comes from: a precompiled build from this version's
  # GitHub release (`.github/workflows/nif.yml`), checked against
  # `checksum-Elixir.Baguette.Native.exs`, so apps compile no Rust for it.
  # It is built from `native/baguette_nif` instead, which needs Rust and
  # the `:rustler` dependency, when:
  #
  #   * `BAGUETTE_BUILD_NIF` is `1` or `true`, or
  #   * there are no checksums: a checkout, not a published package.

  @targets ~w(
    aarch64-apple-darwin
    x86_64-apple-darwin
    aarch64-unknown-linux-gnu
    x86_64-unknown-linux-gnu
    x86_64-pc-windows-msvc
  )

  def targets, do: @targets

  def base_url,
    do: "https://github.com/ziinc/baguette/releases/download/v#{Baguette.version()}"

  def checksums?,
    do: File.exists?(Path.expand("../../../checksum-Elixir.Baguette.Native.exs", __DIR__))

  def force_build?(env \\ System.get_env(), checksums? \\ checksums?()) do
    env["BAGUETTE_BUILD_NIF"] in ["1", "true"] or not checksums?
  end
end
