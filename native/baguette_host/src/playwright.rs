//! Serves the app's windows to Playwright clients (the `playwright` feature).
//! The server only starts when `GPUI_PLAYWRIGHT` is set, such as `9333`.

use tauri_plugin_gpui::GpuiConfig;

pub fn config() -> GpuiConfig {
    GpuiConfig::new().on_launch(|cx| {
        gpui_kit::init(cx);
        if let Some(server) = gpui_playwright::Server::from_env() {
            match server.start(cx) {
                Ok(endpoint) => crate::log_line(&format!("baguette: playwright on {endpoint}")),
                Err(error) => crate::log_line(&format!("baguette: playwright failed: {error}")),
            }
        }
    })
}
