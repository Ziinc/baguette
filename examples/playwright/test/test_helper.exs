# The Playwright test drives a built release: `scripts/e2e-playwright.sh` runs it.
ExUnit.start(exclude: [:playwright])
