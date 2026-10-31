# `mix test --only playwright` runs the end-to-end suite (test/e2e);
# `mix test --only render` the screenshots (needs Vulkan or macOS).
ExUnit.start(exclude: [:playwright, :render])
