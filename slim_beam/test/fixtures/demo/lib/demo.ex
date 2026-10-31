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

  def start(_type, _args) do
    if System.get_env("DEMO_BOOT_CHECK"), do: spawn(fn -> IO.puts(Demo.hello()) end)
    Supervisor.start_link([], strategy: :one_for_one)
  end
end
