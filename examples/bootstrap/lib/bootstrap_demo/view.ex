defmodule BootstrapDemo.View do
  @moduledoc """
  A release dashboard drawn with gpui-bootstrap's components (`bs-*`
  elements). The state lives in `BootstrapDemo.Deployer`; this view only
  renders what it is told.
  """
  use Baguette.View

  def mount(_args) do
    {:ok, %{services: BootstrapDemo.Deployer.subscribe(), dismissed: false}}
  end

  def render(assigns) do
    assigns =
      Map.merge(assigns, %{
        live: Enum.count(assigns.services, &(&1.status == :live)),
        failed: Enum.filter(assigns.services, &(&1.status == :failed))
      })

    ~H"""
    <div class="size-full flex-col gap-4 p-6 bg-[#f8f9fa]">
      <div class="flex-row items-center justify-between">
        <div class="flex-col">
          <bs-heading level="3">Release train</bs-heading>
          <bs-muted>{@live} of {length(@services)} services live</bs-muted>
        </div>
        <div class="flex-row gap-2">
          <bs-button variant="secondary" outline phx-click="reset">Reset</bs-button>
          <bs-button variant="primary" phx-click="deploy_all">Deploy all</bs-button>
        </div>
      </div>

      <bs-alert
        :for={service <- @failed}
        :if={not @dismissed}
        variant="danger"
        heading={"#{service.name} failed"}
        phx-click="dismiss"
        aria-label={"Dismiss #{service.name} alert"}
      >
        <text>Health check failed at {service.progress}%. Retry to roll it out again.</text>
      </bs-alert>

      <bs-card title="Services">
        <bs-list-group flush>
          <bs-list-item :for={service <- @services}>
            <div class="w-full flex-row items-center gap-3">
              <text class="w-24 font-bold">{service.name}</text>
              <div class="w-24 flex-row">
                <bs-badge variant={badge(service.status)} pill>{label(service.status)}</bs-badge>
              </div>
              <div class="flex-1 h-4">
                <bs-progress
                  value={service.progress}
                  variant={badge(service.status)}
                  aria-label={"#{service.name} progress"}
                />
              </div>
              <div class="w-20 flex-row justify-end">
                <bs-button
                  size="sm"
                  variant={if service.status == :failed, do: "danger", else: "primary"}
                  outline
                  disabled={service.status == :deploying}
                  phx-click="deploy"
                  phx-value-name={service.name}
                  aria-label={"Deploy #{service.name}"}
                >
                  {if service.status == :failed, do: "Retry", else: "Deploy"}
                </bs-button>
              </div>
            </div>
          </bs-list-item>
        </bs-list-group>
      </bs-card>
    </div>
    """
  end

  def handle_event("deploy_all", _, assigns) do
    BootstrapDemo.Deployer.deploy_all()
    {:noreply, %{assigns | dismissed: false}}
  end

  def handle_event("deploy", %{"name" => name}, assigns) do
    BootstrapDemo.Deployer.deploy(name)
    {:noreply, %{assigns | dismissed: false}}
  end

  def handle_event("reset", _, assigns) do
    BootstrapDemo.Deployer.reset()
    {:noreply, %{assigns | dismissed: false}}
  end

  def handle_event("dismiss", _, assigns), do: {:noreply, %{assigns | dismissed: true}}

  def handle_info({:deployer, services}, assigns), do: {:noreply, %{assigns | services: services}}

  defp badge(:idle), do: "secondary"
  defp badge(:deploying), do: "info"
  defp badge(:live), do: "success"
  defp badge(:failed), do: "danger"

  defp label(:idle), do: "Idle"
  defp label(:deploying), do: "Deploying"
  defp label(:live), do: "Live"
  defp label(:failed), do: "Failed"
end
