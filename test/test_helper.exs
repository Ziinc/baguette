# `mix test --only playwright` runs the end-to-end suite (test/e2e).
ExUnit.start(exclude: [:playwright])
