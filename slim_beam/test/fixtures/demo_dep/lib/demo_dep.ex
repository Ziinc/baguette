defmodule DemoDep do
  def hello, do: DemoDep.Helper.word()
end

defmodule DemoDep.Helper do
  def word, do: "hello"
end

defmodule DemoDep.Application do
  use Application
  def start(_type, _args), do: Supervisor.start_link([], strategy: :one_for_one)
end

# Nothing names these.
defmodule DemoDep.Unused do
  def x, do: DemoDep.UnusedToo.x()
end

defmodule DemoDep.UnusedToo do
  def x, do: 1
end

# Named in config/config.exs and config/runtime.exs.
defmodule DemoDep.Configured do
  def x, do: "configured"
end

defmodule DemoDep.Runtime do
  def x, do: "runtime"
end

# Reached only by a computed name, so it needs the safelist.
defmodule DemoDep.Safe do
  def x, do: "safe"
end

# Reached through the consolidated String.Chars.
defmodule DemoDep.Struct do
  defstruct [:v]
end

defimpl String.Chars, for: DemoDep.Struct do
  def to_string(%{v: v}), do: "struct #{v}"
end
