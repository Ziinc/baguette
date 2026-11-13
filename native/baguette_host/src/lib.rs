//! Baguette's native host: levain (`levain::run`) running the app's Elixir
//! release on the BEAM (`baguette_beam`).
//!
//! On desktop it is an executable (`src/main.rs`); on Android and iOS the
//! platform loads this library and calls [`run`].

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    levain::run(baguette_beam::Beam, tauri::generate_context!());
}
