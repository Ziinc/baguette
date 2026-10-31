defmodule Baguette.Release.ScanTest do
  use ExUnit.Case, async: true
  alias Baguette.Release.Scan

  setup do
    root = Path.join(System.tmp_dir!(), "baguette-scan-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib/app"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write(root, file, source), do: File.write!(Path.join([root, "lib/app", file]), source)

  test "keeps what the source uses, as Tailwind keeps classes", %{root: root} do
    write(root, "view.ex", ~S"""
    ~H"<icon name="trash" /> <button phx-pick-file="picked">Open</button>"
    """)

    write(root, "other.heex", ~S|<icon name={if @on, do: "undo-2", else: "redo-2"} />|)

    plan = Scan.plan([], root)
    assert plan.excluded == [:open_url]
    assert {:only, tokens} = plan.icons
    assert MapSet.subset?(MapSet.new(~w(trash undo-2 redo-2)), tokens)
  end

  test "open_url and pickers count when called or bound", %{root: root} do
    write(root, "a.ex", "Baguette.App.open_url(url)\n<button phx-pick-save=\"s\" />")
    assert Scan.plan([], root).excluded == []
  end

  test "exclude: drops an API the source uses", %{root: root} do
    write(root, "a.ex", "Baguette.App.open_url(url)")

    assert Scan.plan([baguette: [exclude: [:open_url, :pick]]], root).excluded == [
             :open_url,
             :pick
           ]
  end

  test "the safelist keeps APIs and icons the scan can't see", %{root: root} do
    write(root, "a.ex", "apply(Baguette.App, :open, [])")
    plan = Scan.plan([baguette: [safelist: [apis: [:open_url], icons: ["bell"]]]], root)
    assert plan.excluded == [:pick]
    assert {:only, tokens} = plan.icons
    assert "bell" in tokens
  end

  test "scan: false keeps everything not excluded by name", %{root: root} do
    plan = Scan.plan([baguette: [scan: false, exclude: [:pick]]], root)
    assert plan == %{excluded: [:pick], icons: :all}
  end

  test "scan: [paths: ...] reads those globs instead of lib/", %{root: root} do
    File.mkdir_p!(Path.join(root, "ui"))
    File.write!(Path.join(root, "ui/x.ex"), "Baguette.App.open_url(u) <icon name=\"star\">")
    plan = Scan.plan([baguette: [scan: [paths: ["ui/**/*.ex"]]]], root)
    assert plan.excluded == [:pick]
    assert {:only, tokens} = plan.icons
    assert "star" in tokens
  end

  test "an unknown API in exclude: is an error", %{root: root} do
    assert_raise ArgumentError, ~r/unknown API :canvas/, fn ->
      Scan.plan([baguette: [exclude: [:canvas]]], root)
    end
  end

  describe "check!/2, which Baguette.Test runs on every tree" do
    @plan %{excluded: [:pick], icons: {:only, MapSet.new(["trash"])}}

    test "passes what the release keeps" do
      tree = %{
        "t" => "div",
        "a" => %{},
        "c" => [%{"t" => "icon", "a" => %{"name" => "trash"}, "c" => []}]
      }

      assert Scan.check!(tree, @plan) == :ok
    end

    test "fails an icon the scan missed" do
      tree = %{"t" => "icon", "a" => %{"name" => "bell"}, "c" => []}

      assert_raise ArgumentError, ~r/icon "bell" is left out of the release/, fn ->
        Scan.check!(tree, @plan)
      end
    end

    test "fails a picker when :pick is excluded" do
      tree = %{"t" => "button", "a" => %{"phx-pick-file" => "p"}, "c" => []}

      assert_raise ArgumentError, ~r/phx-pick-file needs the :pick API/, fn ->
        Scan.check!(tree, @plan)
      end
    end
  end
end
