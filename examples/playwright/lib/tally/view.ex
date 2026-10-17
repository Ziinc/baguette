defmodule Tally.View do
  @moduledoc "Counts votes for a few options. The test drives it through Playwright."
  use Baguette.View

  @options ["Elixir", "Rust", "Zig"]

  def mount(_args), do: {:ok, %{votes: Map.new(@options, &{&1, 0})}}

  def render(assigns) do
    assigns =
      Map.merge(assigns, %{options: @options, total: assigns.votes |> Map.values() |> Enum.sum()})

    ~H"""
    <div class="size-full flex-col gap-4 p-6 bg-background text-foreground">
      <text class="text-2xl font-bold">Favourite language</text>
      <div :for={option <- @options} class="flex-row items-center justify-between gap-3">
        <text class="text-lg">{option}: {@votes[option]}</text>
        <button
          class="h-9 px-4 rounded-md flex items-center bg-primary text-primary-foreground hover:opacity-90"
          phx-click="vote"
          phx-value-option={option}
          aria-label={"Vote for #{option}"}
        >
          Vote
        </button>
      </div>
      <div class="flex-row items-center justify-between gap-3">
        <text class="text-sm">Total: {@total}</text>
        <button
          class="h-9 px-4 rounded-md flex items-center bg-muted hover:opacity-90"
          phx-click="reset"
          aria-label="Reset"
        >
          Reset
        </button>
      </div>
    </div>
    """
  end

  def handle_event("vote", %{"option" => option}, assigns) when option in @options,
    do: {:noreply, update_in(assigns.votes[option], &(&1 + 1))}

  def handle_event("reset", _values, assigns),
    do: {:noreply, %{assigns | votes: Map.new(@options, &{&1, 0})}}
end
