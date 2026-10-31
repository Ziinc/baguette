defmodule Baguette.Release.Slim.PlanTest do
  use ExUnit.Case, async: true

  alias Baguette.Release.Slim.{Fake, Plan}

  @moduletag :tmp_dir

  test "purges dependency modules nothing reaches", %{tmp_dir: root} do
    core = Fake.app(root, :core, core: "start() -> dep_a:go().")

    dep =
      Fake.app(root, :dep,
        dep_a: "go() -> dep_b:go().",
        dep_b: "go() -> ok.",
        dep_unused: "go() -> ok."
      )

    plan = Plan.build([core: core, dep: dep], purgeable: [:dep])

    assert plan.purge == %{dep_unused: :dep}
    assert MapSet.equal?(plan.keep, MapSet.new([:core, :dep_a, :dep_b]))
  end

  test "an atom in a literal is an edge", %{tmp_dir: root} do
    core = Fake.app(root, :core, core: "children() -> [{dep_a, []}, \#{impl => dep_b}].")
    dep = Fake.app(root, :dep, dep_a: "x() -> 1.", dep_b: "x() -> 2.", dep_c: "x() -> 3.")

    plan = Plan.build([core: core, dep: dep], purgeable: [:dep])

    assert Map.keys(plan.purge) == [:dep_c]
  end

  test "apps that are not purgeable stay whole and are roots", %{tmp_dir: root} do
    otp = Fake.app(root, :otp, otp_a: "x() -> dep_a:x().", otp_b: "x() -> 1.")
    dep = Fake.app(root, :dep, dep_a: "x() -> 1.", dep_b: "x() -> 2.")

    plan = Plan.build([otp: otp, dep: dep], purgeable: [:dep])

    assert plan.purge == %{dep_b: :dep}
    assert :otp_b in plan.keep
  end

  test "the .app mod and env are roots, its modules list is not", %{tmp_dir: root} do
    dep =
      Fake.app(root, :dep, [dep_app: "x() -> 1.", dep_env: "x() -> 1.", dep_c: "x() -> 1."],
        mod: {:dep_app, []},
        env: [adapter: :dep_env]
      )

    plan = Plan.build([dep: dep], purgeable: [:dep])

    assert Map.keys(plan.purge) == [:dep_c]
  end

  test "extra roots are kept with what they reach", %{tmp_dir: root} do
    dep = Fake.app(root, :dep, dep_a: "x() -> dep_b:x().", dep_b: "x() -> 1.", dep_c: "x() -> 1.")

    plan = Plan.build([dep: dep], purgeable: [:dep], roots: [:dep_a, :not_a_module])

    assert Map.keys(plan.purge) == [:dep_c]
  end

  test "a consolidated module replaces its original", %{tmp_dir: root} do
    proto = Fake.app(root, :proto, proto: "impl_for(_) -> nil.")
    dep = Fake.app(root, :dep, dep_impl: "x() -> 1.")
    consolidated = Path.join(root, "consolidated")
    File.mkdir_p!(consolidated)
    Fake.beam!(consolidated, :proto, "impl_for(_) -> dep_impl.")

    plan = Plan.build([proto: proto, dep: dep], purgeable: [:dep], consolidated: consolidated)
    assert plan.purge == %{}

    plan = Plan.build([proto: proto, dep: dep], purgeable: [:dep], consolidated: nil)
    assert plan.purge == %{dep_impl: :dep}
  end

  test "without consolidation, protocol implementations are kept", %{tmp_dir: root} do
    dep = Fake.app(root, :dep, dep_impl: "'__impl__'(for) -> x.", dep_c: "x() -> 1.")

    plan = Plan.build([dep: dep], purgeable: [:dep])

    assert Map.keys(plan.purge) == [:dep_c]
  end

  test "the reason names what kept a module", %{tmp_dir: root} do
    core = Fake.app(root, :core, core: "x() -> dep_a:x().")
    dep = Fake.app(root, :dep, dep_a: "x() -> 1.")

    plan = Plan.build([core: core, dep: dep], purgeable: [:dep])

    assert plan.reached_by == %{core: :root, dep_a: :core}
  end
end
