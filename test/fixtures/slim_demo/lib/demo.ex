defmodule Demo do
  def hello do
    configured = Application.fetch_env!(:demo, :impl)
    runtime = Application.fetch_env!(:demo, :runtime)
    safe = Module.concat(DemoDep, "Safe")

    Enum.join(
      [DemoDep.hello(), configured.x(), runtime.x(), safe.x(), to_string(%DemoDep.Struct{v: 1})],
      ","
    )
  end
end

defmodule Demo.Application do
  use Application
  require Logger

  def start(_type, _args) do
    if System.get_env("DEMO_BOOT_CHECK") do
      spawn(fn ->
        Logger.info("demo booted")
        IO.puts(Demo.hello())
      end)
    end

    Supervisor.start_link([], strategy: :one_for_one)
  end
end
