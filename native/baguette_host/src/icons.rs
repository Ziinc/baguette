//! The icons a release ships: SVG files in `releases/<vsn>/icons`, which
//! `Baguette.Release` copies from gpui-kit's catalog for the names its
//! source scan found (`Baguette.Release.Scan`), then gpui-kit's own
//! component icons, which the host embeds. One host binary serves every
//! app, so the catalog is not compiled in.

use std::borrow::Cow;
use std::path::PathBuf;
use std::sync::OnceLock;

use tauri_plugin_gpui::gpui::{AssetSource, Result, SharedString};

static DIR: OnceLock<PathBuf> = OnceLock::new();

/// Serves the release's icons from `dir` from now on. Call once, at startup.
pub fn install(dir: PathBuf) {
    let _ = DIR.set(dir);
}

/// The app's asset source.
#[derive(Clone, Copy, Default)]
pub struct Icons;

impl Icons {
    fn dir(&self) -> Option<&'static PathBuf> {
        DIR.get()
    }
}

/// The SVG for `path` (`icons/<name>.svg`) in `dir`, if it is there.
fn shipped(dir: &std::path::Path, path: &str) -> Option<Vec<u8>> {
    let name = path.strip_prefix("icons/")?;
    let valid = name
        .strip_suffix(".svg")?
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
    valid.then(|| std::fs::read(dir.join(name)).ok()).flatten()
}

impl AssetSource for Icons {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        if let Some(svg) = self.dir().and_then(|dir| shipped(dir, path)) {
            return Ok(Some(Cow::Owned(svg)));
        }
        // gpui-kit's component icons; it errs on anything else.
        Ok(gpui_kit::assets::Assets.load(path).ok().flatten())
    }

    fn list(&self, path: &str) -> Result<Vec<SharedString>> {
        let mut paths = gpui_kit::assets::Assets.list(path)?;
        if let Some(entries) = self.dir().and_then(|dir| std::fs::read_dir(dir).ok()) {
            for entry in entries.flatten() {
                let name = format!("icons/{}", entry.file_name().to_string_lossy());
                if name.starts_with(path) {
                    paths.push(name.into());
                }
            }
        }
        Ok(paths)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_shipped_icons_by_their_asset_path() {
        let dir = std::env::temp_dir().join(format!("baguette-icons-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("undo-2.svg"), b"<svg/>").unwrap();
        assert_eq!(
            shipped(&dir, "icons/undo-2.svg").as_deref(),
            Some(&b"<svg/>"[..])
        );
        assert_eq!(shipped(&dir, "icons/zoom-in.svg"), None);
        assert_eq!(shipped(&dir, "icons/../undo-2.svg"), None);
        assert_eq!(shipped(&dir, "undo-2.svg"), None);
    }

    #[test]
    fn serves_gpui_kits_component_icons_without_a_release() {
        assert!(matches!(Icons.load("icons/check.svg"), Ok(Some(_))));
        assert!(matches!(Icons.load("icons/zoom-in.svg"), Ok(None)));
    }
}
