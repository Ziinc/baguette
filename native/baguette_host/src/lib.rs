//! Baguette's native host. Tauri owns the event loop and windows and GPUI
//! renders into them; the host boots the app's Elixir release on a BEAM thread
//! and renders whatever trees the release sends (see `baguette_abi`).
//!
//! On desktop it is an executable (`src/main.rs`); on Android and iOS the
//! platform loads this library and calls [`run`].

mod animation;
mod beam;
mod bridge;
pub mod components;
mod keymap;
mod list;
mod paint;
mod patch;
mod pick;
mod platform;
#[cfg(feature = "playwright")]
mod playwright;
mod style;
mod style_gen;
mod view;
mod windows;

use crate::view::{Frame, Node};

pub(crate) fn notice(text: String) -> Frame {
    Frame {
        root: Some(Node::Element {
            tag: "div".into(),
            attrs: [(
                "class".into(),
                "size-full flex items-center justify-center p-6 text-sm".into(),
            )]
            .into(),
            children: vec![Node::Text(text)],
        }),
        ..Frame::default()
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Info)
            .with_tag("baguette"),
    );
    #[cfg(target_os = "android")]
    beam::android::log_stdio();
    let (host, inbox) = bridge::install();

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .on_menu_event(|_, event| platform::on_menu_event(event))
        .setup(move |app| {
            pick::install(app.handle().clone());
            use tauri::Manager;
            #[cfg(not(target_os = "android"))]
            let release = beam::Release::locate(app.path().resource_dir().ok());
            // A phone has no release directory to point at: the release ships
            // inside this library and is unpacked into the app's data.
            #[cfg(target_os = "android")]
            let release = app
                .path()
                .app_local_data_dir()
                .map_err(|e| e.to_string())
                .and_then(|dir| beam::android::unpack(&dir))
                .and_then(|root| beam::Release::locate_at(root));
            let handle = app.handle().clone();
            let bridge::Inbox { renders, calls } = inbox;
            tauri_plugin_gpui::init_with(
                app,
                tauri_plugin_gpui::GpuiConfig::new()
                    // gpui-kit's icons (a checkbox's tick, an input's clear button).
                    // and every lucide icon, for `<icon name="...">`.
                    .assets(gpui_kit::assets::AllAssets)
                    .on_launch(move |cx| {
                        // gpui-kit's components: text inputs and checkboxes.
                        gpui_kit::init(cx);
                        #[cfg(feature = "playwright")]
                        playwright::start(cx);
                        cx.spawn(async move |cx| {
                            let mut first = true;
                            while let Ok(msg) = renders.recv().await {
                                if std::mem::take(&mut first) {
                                    log_line("baguette: first frame from Elixir");
                                }
                                cx.update(|cx| windows::route(msg, cx));
                            }
                        })
                        .detach();
                        cx.spawn(async move |cx| {
                            while let Ok(json) = calls.recv().await {
                                cx.update(|cx| platform::handle(&json, &handle, cx));
                            }
                        })
                        .detach();
                    }),
            )?;
            let (title, size) = match &release {
                Ok(r) => (
                    r.window.title.clone().unwrap_or(r.name.clone()),
                    (r.window.width, r.window.height),
                ),
                Err(_) => ("Baguette".into(), (480.0, 360.0)),
            };
            let frame = match &release {
                Ok(_) => Frame::default(),
                Err(error) => notice(format!("No Elixir release to run: {error}")),
            };
            windows::open(app.handle(), 0, &title, size, frame)?;

            if let Ok(release) = release {
                beam::start(release, host)?;
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running the Baguette host");
}

/// A line for the platform log: stderr on desktop, logcat on Android.
pub(crate) fn log_line(line: &str) {
    #[cfg(target_os = "android")]
    log::info!("{line}");
    #[cfg(not(target_os = "android"))]
    eprintln!("{line}");
}
