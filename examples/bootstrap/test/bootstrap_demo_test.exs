defmodule BootstrapDemoTest do
  use ExUnit.Case, async: false
  alias Baguette.Test

  setup do
    BootstrapDemo.Deployer.reset()
    :ok
  end

  defp wait_for(text, tries \\ 100) do
    cond do
      Test.text(0) =~ text -> :ok
      tries == 0 -> flunk("never saw #{inspect(text)} in: #{Test.text(0)}")
      true -> Process.sleep(50) && wait_for(text, tries - 1)
    end
  end

  test "deploying everything ends with search failed, and a retry brings it live" do
    wait_for("0 of 4 services live")
    Test.click(0, "Deploy all")
    wait_for("Health check failed")
    wait_for("3 of 4 services live")

    Test.click(0, "Deploy search")
    wait_for("4 of 4 services live")
    refute Test.text(0) =~ "Health check failed"
  end

  test "the failure alert can be dismissed" do
    Test.click(0, "Deploy search")
    wait_for("Health check failed")
    Test.click(0, "Dismiss search alert")
    refute Test.text(0) =~ "Health check failed"
  end
end
