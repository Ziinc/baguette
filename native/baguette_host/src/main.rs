//! Baguette's native host. Tauri owns the event loop and windows and GPUI
//! renders into them; the host boots the app's Elixir release on a BEAM thread
//! and renders whatever trees the release sends (see `baguette_abi`).

mod beam;
#[cfg(feature = "bootstrap")]
mod bootstrap;
mod bridge;
mod style;
mod view;

use tauri_plugin_gpui::{GpuiWindowExt, gpui::AppContext};

use crate::view::{Frame, Node, Root};

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

fn main() {
    let (host, renders) = bridge::install();

    tauri::Builder::default()
        .setup(move |app| {
            use tauri::Manager;
            let release = beam::Release::locate(app.path().resource_dir().ok());
            #[cfg(not(feature = "bootstrap"))]
            tauri_plugin_gpui::init(app)?;
            #[cfg(feature = "bootstrap")]
            tauri_plugin_gpui::init_with(
                app,
                tauri_plugin_gpui::GpuiConfig::new()
                    .assets(gpui_kit::assets::Assets)
                    .on_launch(gpui_bootstrap::init),
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
                let root = cx.new(|_| Root { window: 0, frame });
                let handle = root.clone();
                cx.spawn(async move |cx| {
                    while let Ok(msg) = renders.recv().await {
                        // One window for now: the BEAM renders window 0.
                        if msg.window != 0 {
                            continue;
                        }
                        let frame = match serde_json::from_slice::<Frame>(&msg.json) {
                            Ok(frame) => frame,
                            Err(error) => notice(format!("Invalid render from Elixir: {error}")),
                        };
                        handle.update(cx, |root, cx| {
                            root.frame = frame;
                            cx.notify();
                        });
                    }
                })
                .detach();
                root
            };
            // gpui-kit's components need its `Root` (focus, dialogs, theme).
            #[cfg(feature = "bootstrap")]
            window.attach_gpui_view(Default::default(), move |window, cx| {
                let root = build(cx);
                cx.new(|cx| gpui_kit::base::Root::new(root, window, cx))
            })?;
            #[cfg(not(feature = "bootstrap"))]
            window.attach_gpui(build)?;

            if let Ok(release) = release {
                beam::start(release, host)?;
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running the Baguette host");
}
