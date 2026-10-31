defmodule SlimBeam.Fixture do
  @moduledoc false
  # Builds the `test/fixtures/demo` release with the given slim_beam options.

  @demo Path.expand("../fixtures/demo", __DIR__)

  def release!(options) do
    {out, status} =
      System.cmd("mix", ["release", "--overwrite"],
        cd: @demo,
        env: [{"MIX_ENV", "prod"}, {"SLIM_BEAM", inspect(options)}],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("mix release failed:\n" <> out)
    {Path.join(@demo, "_build/prod/rel/demo"), out}
  end

  def run(path, args, env \\ []) do
    System.cmd(Path.join(path, "bin/demo"), args, env: env, stderr_to_stdout: true)
  end

  def ebin(path, app), do: hd(Path.wildcard(Path.join([path, "lib", "#{app}-*", "ebin"])))
end
