defmodule Baguette.Release.SlimTest do
  use ExUnit.Case, async: true

  alias Baguette.Release.Slim

  @otp [:kernel, :stdlib, :sasl, :compiler, :crypto, :public_key, :ssl, :inets, :asn1]
  @elixir [:elixir, :logger, :iex, :eex]
  @deps [:telemetry, :telemetry_poller, :recon, :runtime_tools, :plug, :my_app]

  test "every app but the project's own and the core may lose modules" do
    assert Slim.purgeable(@otp ++ @elixir ++ @deps, [:my_app], []) ==
             [:sasl, :compiler, :elixir, :iex, :eex, :recon, :runtime_tools, :plug]
  end

  test "keep: [apps: ...] keeps apps whole" do
    assert Slim.purgeable([:recon, :runtime_tools, :plug], [],
             keep: [apps: [:recon, :runtime_tools]]
           ) ==
             [:plug]
  end

  test "the options are the release's baguette: options" do
    assert Slim.options(baguette: [keep: [modules: [A]]], other: 1) == [keep: [modules: [A]]]
    assert Slim.kept_modules(keep: [modules: [A]]) == [A]
    assert Slim.options([]) == []
  end
end
