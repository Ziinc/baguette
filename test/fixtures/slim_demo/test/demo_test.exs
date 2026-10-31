defmodule DemoTest do
  use ExUnit.Case

  test "hello" do
    assert Demo.hello() =~ "hello"
    if System.get_env("LOAD_UNUSED"), do: DemoDep.Unused.x()
  end
end
