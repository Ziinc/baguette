//! Renders one Baguette frame to a PNG, for screenshot tests.
//!
//! ```sh
//! echo '{"root": {"t": "text", "c": ["Hi"]}}' |
//!   cargo run -p baguette_view --features render --bin baguette_render -- --width 400 --height 300 > out.png
//! ```
//!
//! Reads the frame JSON `Baguette.Host` stores from `--frame` (or stdin) and
//! writes the PNG to `--out` (or stdout). Draws offscreen with GPUI's headless renderer: Metal on macOS,
//! Vulkan on Linux (lavapipe from `mesa-vulkan-drivers` without a GPU).

use std::io::{Read, Write};
use std::sync::Arc;

use anyhow::{Context as _, Result, bail};
use baguette_view::{Frame, Root};
use gpui::{
    AnyWindowHandle, AppContext, Bounds, HeadlessAppContext, WindowBounds, WindowOptions, px, size,
};

fn main() {
    if let Err(error) = run() {
        eprintln!("baguette_render: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let (mut width, mut height) = (800., 600.);
    let (mut frame_path, mut out) = (None, None);
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let value = args
            .next()
            .with_context(|| format!("{arg} needs a value"))?;
        let number = || {
            value
                .parse::<f32>()
                .with_context(|| format!("{arg} {value}: not a number"))
        };
        match arg.as_str() {
            "--width" => width = number()?,
            "--height" => height = number()?,
            "--frame" => frame_path = Some(value),
            "--out" => out = Some(value),
            _ => bail!(
                "unknown argument {arg}; usage: baguette_render [--width px] [--height px] [--frame frame.json] [--out out.png]"
            ),
        }
    }
    let json = match &frame_path {
        Some(path) => std::fs::read_to_string(path).with_context(|| format!("reading {path}"))?,
        None => {
            let mut json = String::new();
            std::io::stdin().read_to_string(&mut json)?;
            json
        }
    };
    let frame: Frame = serde_json::from_str(&json).context("parsing the frame JSON")?;

    if gpui_platform::current_headless_renderer()?.is_none() {
        bail!(
            "GPUI has no headless renderer here; render on macOS or Linux with Vulkan (e.g. lavapipe)"
        );
    }
    let mut cx = HeadlessAppContext::with_platform(
        gpui_platform::current_platform(true).text_system(),
        Arc::new(()),
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
            cx.open_window(options, |_, cx| {
                cx.new(|_| Root::new(0, |_| {}).with_frame(frame))
            })
        })?
        .into();
    // Draw a few times so layout that depends on the previous frame (measured
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
    match &out {
        Some(path) => std::fs::write(path, &png).with_context(|| format!("writing {path}"))?,
        None => std::io::stdout().write_all(&png)?,
    }
    Ok(())
}
