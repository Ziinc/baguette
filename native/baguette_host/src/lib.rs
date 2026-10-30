//! Baguette's native host. Tauri owns the event loop and windows and GPUI
//! renders into them; the host boots the app's Elixir release on a BEAM thread
//! and renders whatever trees the release sends (see `baguette_abi`).
//!
//! On desktop it is an executable (`src/main.rs`); on Android and iOS the
//! platform loads this library and calls [`run`].

mod beam;
mod bridge;
pub mod components;
mod list;
mod pick;
#[cfg(feature = "playwright")]
mod playwright;
mod style;
mod view;

use tauri_plugin_gpui::{GpuiWindowExt, gpui::AppContext};

use crate::view::{Frame, Message, Node, Root};

fn notice(text: String) -> Frame {
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
    let (host, renders) = bridge::install();

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
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
            tauri_plugin_gpui::init_with(
                app,
                tauri_plugin_gpui::GpuiConfig::new()
                    // gpui-kit's icons (a checkbox's tick, an input's clear button).
                    // and every lucide icon, for `<icon name="...">`.
                    .assets(gpui_kit::assets::AllAssets)
                    .on_launch(|cx| {
                        // gpui-kit's components: text inputs and checkboxes.
                        gpui_kit::init(cx);
                        #[cfg(feature = "playwright")]
                        playwright::start(cx);
                    }),
            )?;
            let (title, (width, height)) = match &release {
                Ok(r) => (
                    r.window.title.clone().unwrap_or(r.name.clone()),
                    (r.window.width, r.window.height),
                ),
                Err(_) => ("Baguette".into(), (480.0, 360.0)),
            };
            let window = tauri::WindowBuilder::new(app, "main")
                .title(title)
                .inner_size(width, height)
                .build()?;

            let frame = match &release {
                Ok(_) => Frame::default(),
                Err(error) => notice(format!("No Elixir release to run: {error}")),
            };
            let build = move |cx: &mut tauri_plugin_gpui::gpui::App| {
                let root = cx.new(|_| Root::new(0, frame));
                let handle = root.clone();
                // Window shortcuts (`phx-window-keydown`) hear every keystroke,
                // wherever focus is, once GPUI has dispatched it.
                let keys = root.downgrade();
                cx.observe_keystrokes(move |event, _, cx| {
                    if let Some(root) = keys.upgrade() {
                        root.read(cx).on_keystroke(event);
                    }
                })
                .detach();
                cx.spawn(async move |cx| {
                    let mut first = true;
                    while let Ok(msg) = renders.recv().await {
                        // One window for now: the BEAM renders window 0.
                        if msg.window != 0 {
                            continue;
                        }
                        if std::mem::take(&mut first) {
                            log_line("baguette: first frame from Elixir");
                        }
                        match serde_json::from_slice::<Message>(&msg.json) {
                            Ok(Message::Frame(frame)) => {
                                handle.update(cx, |root, cx| root.show(frame, cx))
                            }
                            Ok(Message::Rows { rows }) => {
                                handle.update(cx, |root, cx| root.rows(rows, cx))
                            }
                            Err(error) => {
                                let frame = notice(format!("Invalid render from Elixir: {error}"));
                                handle.update(cx, |root, cx| root.show(frame, cx))
                            }
                        }
                    }
                })
                .detach();
                root
            };
            // gpui-kit's Root hosts its components (focus, theme, popovers)
            // and, for Playwright, observes what each frame paints.
            window.attach_gpui_view(Default::default(), move |window, cx| {
                let root = build(cx);
                cx.new(|cx| gpui_kit::base::Root::new(root, window, cx))
            })?;

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
