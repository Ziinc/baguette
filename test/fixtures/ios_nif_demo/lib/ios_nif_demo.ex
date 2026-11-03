defmodule IosNifDemo.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # The smoke test reads this from the device log.
    Logger.info("ios_nif_demo: add=#{IosNifDemoRust.add(2, 3)} mul=#{IosNifDemoC.mul(3, 4)}")
    Supervisor.start_link([IosNifDemo.View], strategy: :one_for_one)
  end
end

defmodule IosNifDemo.View do
  @moduledoc false
  use Baguette.View

  def mount(_args), do: {:ok, %{sum: IosNifDemoRust.add(2, 3), product: IosNifDemoC.mul(3, 4)}}

  def render(assigns) do
    ~H"""
    <div class="size-full flex-col items-center justify-center gap-2">
      <text>Rust: 2 + 3 = {@sum}</text>
      <text>C: 3 × 4 = {@product}</text>
    </div>
    """
  end
end
