defmodule Baguette.Release.Slim.Fixture do
  @moduledoc false
  # Runs mix in the `test/fixtures/slim_demo` project, which slims its release
  # with this build's Baguette.Release.Slim.

  @demo Path.expand("../fixtures/slim_demo", __DIR__)

  def demo, do: @demo

  @doc "Runs `mix args` in the fixture with `MIX_ENV=env` and the slimming `options`."
  def mix(args, env, options, extra \\ []) do
    System.cmd("mix", args,
      cd: @demo,
      env: [{"MIX_ENV", env}, {"SLIM", inspect(options)}] ++ extra,
      stderr_to_stdout: true
    )
  end

  def release!(options) do
    {out, status} = mix(["release", "--overwrite"], "prod", options)
    if status != 0, do: raise("mix release failed:\n" <> out)
    {Path.join(@demo, "_build/prod/rel/demo"), out}
  end

  def run(path, args, env \\ []) do
    System.cmd(Path.join(path, "bin/demo"), args, env: env, stderr_to_stdout: true)
  end

  def ebin(path, app), do: hd(Path.wildcard(Path.join([path, "lib", "#{app}-*", "ebin"])))
end
