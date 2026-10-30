defmodule Baguette.Kit do
  @moduledoc """
  gpui-kit's components as function components, generated from
  `priv/components/gpui-kit.json`.

      import Baguette.Kit

      <.tag variant="danger" pill>Failed</.tag>
      <.progress value={@done} aria-label="Upload" class="w-48" />
      <.kbd keys="cmd-k" />

  The host draws them when it is built with the `gpui-kit` component set,
  which it is unless a release's `baguette: [components: [...]]` leaves it
  out (see `Baguette.Release`).
  """
  use Baguette.Components, manifest: "../../priv/components/gpui-kit.json", prefix: "kit-"
end
