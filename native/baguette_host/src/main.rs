//! Baguette's native host. Tauri owns the event loop and windows and GPUI
//! renders into them; the host boots the app's Elixir release on a BEAM thread
//! and renders whatever trees the release sends (see `baguette_abi`).

mod beam;
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
    let release = beam::Release::locate();

    tauri::Builder::default()
        .setup(move |app| {
            tauri_plugin_gpui::init(app)?;
            let title = release.as_ref().map(|r| r.name.clone()).unwrap_or("Baguette".into());
            let window = tauri::WindowBuilder::new(app, "main")
                .title(title)
                .inner_size(480.0, 360.0)
                .build()?;

            let frame = match &release {
                Ok(_) => Frame::default(),
                Err(error) => notice(format!("No Elixir release to run: {error}")),
            };
            window.attach_gpui(move |cx| {
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
                        let _ = handle.update(cx, |root, cx| {
                            root.frame = frame;
                            cx.notify();
                        });
                    }
                })
                .detach();
                root
            })?;

            if let Ok(release) = release {
                beam::start(release, host)?;
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running the Baguette host");
}
