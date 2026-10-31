//! `baguette_host --render` (the `render` feature): draws one frame offscreen
//! with GPUI's headless renderer and returns it as a PNG, for screenshot
//! tests (`Baguette.Test.render_png`). Uses the same view code as the app's
//! windows, without Tauri, the BEAM or a display: Metal on macOS, Vulkan on
//! Linux (lavapipe from `mesa-vulkan-drivers` without a GPU).

use std::sync::Arc;

use anyhow::{Context as _, Result, bail};
use gpui::{
    AnyWindowHandle, AppContext, Bounds, HeadlessAppContext, WindowBounds, WindowOptions, px, size,
};

use crate::view::{Frame, Root};

/// Draws `frame` (the JSON Elixir sends a window) in a `width` by `height`
/// window, in logical pixels, at the headless renderer's scale.
pub fn png(frame: &[u8], width: f32, height: f32) -> Result<Vec<u8>> {
    let frame: Frame = serde_json::from_slice(frame).context("parsing the frame JSON")?;
    if gpui_platform::current_headless_renderer()?.is_none() {
        bail!(
            "GPUI has no headless renderer here; render on macOS, or on Linux with Vulkan (such as lavapipe)"
        );
    }
    let mut cx = HeadlessAppContext::with_platform(
        gpui_platform::current_platform(true).text_system(),
        Arc::new(gpui_kit::assets::AllAssets),
        gpui_platform::current_headless_renderer,
    );
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds {
            origin: Default::default(),
            size: size(px(width), px(height)),
        })),
        focus: false,
        show: false,
        ..Default::default()
    };
    let handle: AnyWindowHandle = cx
        .update(|cx| {
            gpui_kit::init(cx);
            cx.open_window(options, |window, cx| {
                // As `windows::open` does: gpui-kit's Root around the view.
                let root = cx.new(|_| Root::new(0, Frame::default()));
                root.update(cx, |root, cx| root.show(frame, cx));
                cx.new(|cx| gpui_kit::base::Root::new(root, window, cx))
            })
        })?
        .into();
    // A few draws, so layout that depends on the previous one (measured
    // text, scroll) settles.
    for _ in 0..3 {
        cx.run_until_parked();
        cx.update_window(handle, |_, window, cx| {
            window.refresh();
            window.draw(cx).clear(cx);
        })?;
    }
    let image = cx
        .capture_screenshot(handle)
        .context("capturing the window")?;
    let mut png = Vec::new();
    image.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)?;
    Ok(png)
}
