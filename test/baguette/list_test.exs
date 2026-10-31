defmodule Baguette.ListTest do
  use ExUnit.Case, async: false
  alias Baguette.Test

  defmodule Jobs do
    use Baguette.View

    def mount(_args), do: {:ok, %{count: 10_000, prefix: "Job", asked: []}}

    def render(assigns) do
      ~H"""
      <div class="flex-col">
        <text>{@count} jobs</text>
        <list id="jobs" rows={@count} phx-rows="jobs" class="h-64" />
      </div>
      """
    end

    def handle_rows("jobs", range, assigns) do
      rows =
        for i <- range do
          assigns = %{i: i, prefix: assigns.prefix}

          ~H"""
          <button phx-click="open" phx-value-id={@i}>{@prefix} {@i}</button>
          """
        end

      {:reply, rows, %{assigns | asked: [range | assigns.asked]}}
    end

    def handle_event("open", %{"id" => id}, assigns),
      do: {:noreply, %{assigns | prefix: "Opened #{id}"}}

    def handle_event("rename", _values, assigns), do: {:noreply, %{assigns | prefix: "Task"}}

    def handle_info(:shrink, assigns), do: {:noreply, %{assigns | count: 3}}
  end

  setup do
    window = System.unique_integer([:positive])
    pid = start_supervised!({Jobs, window: window})
    %{window: window, pid: pid}
  end

  test "rows are asked for by range, and only when shown", %{window: window, pid: pid} do
    assert Test.text(window) == "10000 jobs"
    assert :sys.get_state(pid).assigns.asked == []

    Test.show_rows(window, "jobs", 20..24)
    assert Test.text(window) == "10000 jobs Job 20 Job 21 Job 22 Job 23 Job 24"
    assert :sys.get_state(pid).assigns.asked == [20..24]
  end

  test "rows hold events like any element", %{window: window} do
    Test.show_rows(window, "jobs", 0..2)
    Test.click(window, "Job 1")
    assert Test.text(window) =~ "Opened 1 1"
  end

  test "every render refreshes the rows on screen", %{window: window} do
    Test.show_rows(window, "jobs", 5..6)
    send_event(window, "rename")
    assert Test.text(window) == "10000 jobs Task 5 Task 6"
  end

  test "rows past the end are neither asked for nor kept", %{window: window, pid: pid} do
    Test.show_rows(window, "jobs", 0..4)
    send(pid, :shrink)
    assert Test.text(window) == "3 jobs Job 0 Job 1 Job 2"
  end

  test "showing rows of a list that isn't there fails", %{window: window} do
    assert_raise ArgumentError, ~r/no list "nope"/, fn -> Test.show_rows(window, "nope", 0..1) end
  end

  defmodule Plain do
    # A list without an id is keyed by its path, as the host keys it; one
    # inside another's rows by its path there.
    use Baguette.View

    def mount(_args), do: {:ok, %{label: "Row"}}

    def render(assigns) do
      ~H"""
      <div><list rows="100" phx-rows="outer" /></div>
      """
    end

    def handle_rows("outer", range, assigns) do
      rows =
        for i <- range do
          assigns = %{i: i, label: assigns.label}

          ~H"""
          <div><text>{@label} {@i}</text><list id={"inner-#{@i}"} rows="5" phx-rows="inner" /></div>
          """
        end

      {:reply, rows, assigns}
    end

    def handle_rows("inner", range, assigns),
      do: {:reply, Enum.map(range, &"#{assigns.label} sub #{&1}"), assigns}

    def handle_event("rename", _values, assigns), do: {:noreply, %{assigns | label: "Item"}}
  end

  test "lists without an id, and lists in rows, keep their rows through renders" do
    window = System.unique_integer([:positive])
    start_supervised!({Plain, window: window})

    ask(window, "outer", "root.0", 0..1)
    ask(window, "inner", "inner-0", 0..1)
    send_event(window, "rename")

    lists = Baguette.Host.last_frame(window)["lists"]
    assert %{"start" => 0, "rows" => [_, _]} = lists["root.0"]
    assert %{"start" => 0, "rows" => ["Item sub 0", "Item sub 1"]} = lists["inner-0"]
  end

  defp ask(window, event, id, first..last//1) do
    Baguette.Host.dispatch(%{
      "type" => "rows",
      "window" => window,
      "event" => event,
      "id" => id,
      "start" => first,
      "end" => last + 1,
      "visible" => [first, last + 1]
    })

    Test.text(window)
  end

  defp send_event(window, event) do
    Baguette.Host.dispatch(%{"type" => "click", "window" => window, "event" => event})
    Test.text(window)
  end
end
