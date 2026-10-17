defmodule FirehoseTest do
  use ExUnit.Case, async: false
  alias Baguette.Test

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held; screen: #{Test.text(0)}")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  test "events flow from the producer through to acknowledgement" do
    eventually(fn -> Firehose.Stats.snapshot().acked > 50 end)
    snapshot = Firehose.Stats.snapshot()
    assert Enum.all?(snapshot.processed, &(&1 > 0)), "every processor did work"
    assert snapshot.batches.warehouse.count > 0
    assert Test.text(0) =~ "Throughput"
  end

  test "controls change the rate and inject failures" do
    Test.click(0, "Faster")
    assert Test.text(0) =~ "800/s"
    Test.click(0, "Slower")
    assert Test.text(0) =~ "400/s"

    Test.click(0, "Chaos")
    assert Test.text(0) =~ "Chaos 10%"
    eventually(fn -> Firehose.Stats.snapshot().failed > 0 end)
    Test.click(0, "Chaos")
    assert Test.text(0) =~ "Chaos 0%"
  end
end
