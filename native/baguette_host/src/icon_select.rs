//! Which of gpui-kit's icons a release embeds, and the asset source that
//! serves them. `build.rs` includes this file, so it uses only `std`.

use std::collections::BTreeSet;

/// gpui-kit's `IconName` variant for an icon file's stem (`undo-2` is
/// `Undo2`), as gpui-kit-assets' build script names them.
pub fn variant(stem: &str) -> String {
    stem.split(['-', '_', '.'])
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut chars = part.chars();
            let first = chars.next().unwrap().to_ascii_uppercase();
            format!("{first}{}", chars.as_str().to_ascii_lowercase())
        })
        .collect()
}

/// The catalog's icons among `words` (the release's source scan).
pub fn select(catalog: &BTreeSet<String>, words: &BTreeSet<String>) -> Vec<String> {
    catalog.intersection(words).cloned().collect()
}

/// `Icons`: `selected` (or, with `None`, the whole catalog) plus gpui-kit's
/// own component icons.
pub fn source(selected: Option<&[String]>) -> String {
    let Some(selected) = selected else {
        return "/// Every icon in gpui-kit's catalog.\n\
                pub use gpui_kit::assets::AllAssets as Icons;\n"
            .into();
    };
    let variants: Vec<String> = selected.iter().map(|stem| variant(stem)).collect();
    format!(
        "gpui_kit::assets::icon_assets!(Selected, [{}]);\n\
         \n\
         /// The {} icons the release's source names, then gpui-kit's own.\n\
         #[derive(Clone, Copy, Default)]\n\
         pub struct Icons;\n\
         \n\
         impl tauri_plugin_gpui::gpui::AssetSource for Icons {{\n\
         \x20   fn load(&self, path: &str) -> tauri_plugin_gpui::gpui::Result<Option<std::borrow::Cow<'static, [u8]>>> {{\n\
         \x20       match Selected.load(path)? {{\n\
         \x20           Some(icon) => Ok(Some(icon)),\n\
         \x20           None => gpui_kit::assets::Assets.load(path),\n\
         \x20       }}\n\
         \x20   }}\n\
         \n\
         \x20   fn list(&self, path: &str) -> tauri_plugin_gpui::gpui::Result<Vec<tauri_plugin_gpui::gpui::SharedString>> {{\n\
         \x20       let mut paths = Selected.list(path)?;\n\
         \x20       paths.extend(gpui_kit::assets::Assets.list(path)?);\n\
         \x20       Ok(paths)\n\
         \x20   }}\n\
         }}\n",
        variants.join(", "),
        variants.len(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set(words: &[&str]) -> BTreeSet<String> {
        words.iter().map(|w| w.to_string()).collect()
    }

    #[test]
    fn names_variants_as_gpui_kit_does() {
        assert_eq!(variant("undo-2"), "Undo2");
        assert_eq!(variant("a-large-small"), "ALargeSmall");
        assert_eq!(variant("chart-pie"), "ChartPie");
    }

    #[test]
    fn keeps_the_scanned_words_that_name_icons() {
        let catalog = set(&["bell", "plus", "trash", "undo-2"]);
        let words = set(&["plus", "defmodule", "trash", "class"]);
        assert_eq!(select(&catalog, &words), ["plus", "trash"]);
    }

    #[test]
    fn serves_the_selection_or_everything() {
        let some = source(Some(&["plus".into(), "undo-2".into()]));
        assert!(some.contains("icon_assets!(Selected, [Plus, Undo2]);"));
        assert!(some.contains("The 2 icons"));
        assert!(source(None).contains("AllAssets as Icons"));
    }
}
