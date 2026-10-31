defmodule Baguette.Release.Slim.ReportTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "sizes break a release down by top-level directory and app", %{tmp_dir: root} do
    for {file, bytes} <- [
          {"erts-17.1.1/bin/beam.smp", 7},
          {"lib/a-1.0/ebin/a.beam", 3},
          {"lib/b-2.0/ebin/b.beam", 2},
          {"releases/0.1.0/start.boot", 1}
        ] do
      path = Path.join(root, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, String.duplicate("x", bytes))
    end

    assert Baguette.Release.Slim.Report.sizes(root) == %{
             total: 13,
             erts: 7,
             lib: 5,
             releases: 1,
             bin: 0,
             apps: %{"a" => 3, "b" => 2}
           }
  end
end
