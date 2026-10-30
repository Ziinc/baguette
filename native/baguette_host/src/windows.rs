//! The app's windows: each a Tauri window with a GPUI `Root` in it,
//! numbered as Elixir numbers them (window 0 is the main one).

use std::collections::HashMap;

use tauri_plugin_gpui::GpuiWindowExt;
use tauri_plugin_gpui::gpui::{self, AppContext, Global, WeakEntity};

use crate::bridge::RenderMsg;
use crate::view::{Frame, Message, Root};

/// Each open window's root, and what Elixir sent windows not open yet.
#[derive(Default)]
struct Windows {
    roots: HashMap<u32, WeakEntity<Root>>,
    queued: HashMap<u32, Vec<Vec<u8>>>,
}

impl Global for Windows {}

/// The Tauri label of window `id`.
pub fn label(id: u32) -> String {
    match id {
        0 => "main".into(),
        id => format!("window-{id}"),
    }
}

/// Opens window `id`, showing `frame` until Elixir renders it.
pub fn open(
    app: &tauri::AppHandle,
    id: u32,
    title: &str,
    (width, height): (f64, f64),
    frame: Frame,
) -> Result<(), Box<dyn std::error::Error>> {
    let window = tauri::WindowBuilder::new(app, label(id))
        .title(title)
        .inner_size(width, height)
        .build()?;
    // gpui-kit's Root hosts its components (focus, theme, popovers) and,
    // for Playwright, observes what each frame paints.
    window.attach_gpui_view(Default::default(), move |window, cx| {
        let root = cx.new(|_| Root::new(id, frame));
        // Window shortcuts (`phx-window-keydown`) hear every keystroke,
        // wherever focus is, once GPUI has dispatched it.
        let keys = root.downgrade();
        cx.observe_keystrokes(move |event, _, cx| {
            if let Some(root) = keys.upgrade() {
                root.read(cx).on_keystroke(event);
            }
        })
        .detach();
        let appearance = window.observe_window_appearance(move |window, _| {
            crate::bridge::emit(&serde_json::json!({
                "type": "appearance",
                "window": id,
                "appearance": crate::platform::appearance(window.appearance()),
            }));
        });
        root.update(cx, |root, _| root.keep(appearance));
        let queued = {
            let windows = cx.default_global::<Windows>();
            windows.roots.insert(id, root.downgrade());
            windows.queued.remove(&id).unwrap_or_default()
        };
        for json in queued {
            deliver(&root, &json, cx);
        }
        cx.new(|cx| gpui_kit::base::Root::new(root, window, cx))
    })?;
    Ok(())
}

/// Shows a render on its window, or keeps it until that window opens.
pub fn route(msg: RenderMsg, cx: &mut gpui::App) {
    let windows = cx.default_global::<Windows>();
    match windows
        .roots
        .get(&msg.window)
        .and_then(|root| root.upgrade())
    {
        Some(root) => deliver(&root, &msg.json, cx),
        None => {
            windows.roots.remove(&msg.window);
            // Only the latest frame matters; rows and patches follow it.
            let queue = windows.queued.entry(msg.window).or_default();
            if is_frame(&msg.json) {
                queue.clear();
            }
            queue.push(msg.json);
        }
    }
}

fn is_frame(json: &[u8]) -> bool {
    matches!(serde_json::from_slice(json), Ok(Message::Frame(_)))
}

fn deliver(root: &gpui::Entity<Root>, json: &[u8], cx: &mut gpui::App) {
    match serde_json::from_slice::<Message>(json) {
        Ok(Message::Frame(frame)) => root.update(cx, |root, cx| root.show(frame, cx)),
        Ok(Message::Rows { rows }) => root.update(cx, |root, cx| root.rows(rows, cx)),
        Ok(Message::Patch { patch, lists }) => {
            root.update(cx, |root, cx| root.patch(patch, lists, cx))
        }
        Err(error) => {
            let frame = crate::notice(format!("Invalid render from Elixir: {error}"));
            root.update(cx, |root, cx| root.show(frame, cx))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels_windows() {
        assert_eq!(label(0), "main");
        assert_eq!(label(3), "window-3");
    }

    #[test]
    fn tells_frames_from_patches_and_rows() {
        assert!(is_frame(br#"{"theme": {}, "root": null}"#));
        assert!(!is_frame(br#"{"patch": []}"#));
        assert!(!is_frame(
            br#"{"rows": {"id": "a", "start": 0, "rows": []}}"#
        ));
    }
}
