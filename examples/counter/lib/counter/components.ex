defmodule Counter.Components do
  @moduledoc "The app's own components. Restyle them freely."
  use Phoenix.Component

  attr(:variant, :atom, default: :primary)
  attr(:rest, :global, include: ~w(phx-click phx-value-by disabled aria-label))
  slot(:inner_block, required: true)

  def button(assigns) do
    ~H"""
    <button
      class={[
        "h-10 min-w-10 px-4 rounded-md flex items-center justify-center text-lg font-semibold cursor-pointer",
        "hover:opacity-90 active:opacity-75 disabled:opacity-50",
        @variant == :primary && "bg-primary text-primary-foreground",
        @variant == :ghost && "bg-muted text-foreground"
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end
end
