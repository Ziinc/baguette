//! Serves the Playwright protocol from inside the app, so stock Playwright
//! clients drive it like a browser page: `GPUI_PLAYWRIGHT=9333` starts the
//! server on `ws://127.0.0.1:9333/`. Elements come from the view tree's roles,
//! `aria-label`s and text (see `view.rs`).

use tauri_plugin_gpui::gpui::App;

pub fn start(cx: &mut App) {
    let Some(server) = gpui_playwright::Server::from_env() else {
        return;
    };
    if let Err(error) = server.start(cx) {
        crate::log_line(&format!(
            "baguette: gpui-playwright failed to start: {error}"
        ));
    }
}
