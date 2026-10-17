//! Tailwind-style class strings mapped onto GPUI's `Styled` API.
//!
//! Only utilities GPUI can honour are supported; anything else is reported
//! once per class through [`unknown`] and otherwise ignored. Spacing follows
//! Tailwind's scale (1 = 4px), and colours are theme tokens (`bg-primary`),
//! `white`, `black`, `transparent` or arbitrary hex (`bg-[#2563eb]`).

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use gpui::{FontWeight, Hsla, Rgba, Styled, px, relative, rgb};

/// Theme tokens sent by Elixir, by name.
pub type Theme = HashMap<String, String>;

/// The state variants a class can be scoped to.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Variant {
    Base,
    Hover,
    Active,
    Disabled,
}

/// Splits `classes` into the utilities for `variant`, with the prefix removed.
pub fn for_variant(classes: &str, variant: Variant) -> impl Iterator<Item = &str> {
    classes.split_whitespace().filter_map(move |class| {
        let (prefix, rest) = match class.split_once(':') {
            Some((prefix, rest)) => (Some(prefix), rest),
            None => (None, class),
        };
        matches!(
            (prefix, variant),
            (None, Variant::Base)
                | (Some("hover"), Variant::Hover)
                | (Some("active"), Variant::Active)
                | (Some("disabled"), Variant::Disabled)
        )
        .then_some(rest)
    })
}

pub fn apply<S: Styled>(
    mut style: S,
    utilities: impl Iterator<Item = impl AsRef<str>>,
    theme: &Theme,
) -> S {
    for utility in utilities {
        style = apply_one(style, utility.as_ref(), theme);
    }
    style
}

fn apply_one<S: Styled>(s: S, class: &str, theme: &Theme) -> S {
    match class {
        "flex" => s.flex(),
        "flex-row" => s.flex().flex_row(),
        "flex-col" => s.flex().flex_col(),
        "flex-wrap" => s.flex_wrap(),
        "flex-1" => s.flex_1(),
        "min-w-0" => s.min_w(px(0.)),
        "items-stretch" => s.items_stretch(),
        "text-right" => s.text_right(),
        "text-center" => s.text_center(),
        "font-mono" => s.font_family("monospace"),
        "border-2" => s.border_2(),
        "border-l-2" => s.border_l_2(),
        "border-l-4" => s.border_l_4(),
        "grow" => s.flex_grow_1(),
        "shrink-0" => s.flex_shrink_0(),
        "items-start" => s.items_start(),
        "items-center" => s.items_center(),
        "items-end" => s.items_end(),
        "justify-start" => s.justify_start(),
        "justify-center" => s.justify_center(),
        "justify-end" => s.justify_end(),
        "justify-between" => s.justify_between(),
        "size-full" => s.size_full(),
        "w-full" => s.w_full(),
        "h-full" => s.h_full(),
        "overflow-hidden" => s.overflow_hidden(),
        "border" => s.border_1(),
        "rounded" => s.rounded(px(4.)),
        "rounded-sm" => s.rounded(px(2.)),
        "rounded-md" => s.rounded(px(6.)),
        "rounded-lg" => s.rounded(px(8.)),
        "rounded-xl" => s.rounded(px(12.)),
        "rounded-full" => s.rounded_full(),
        "shadow-sm" => s.shadow_sm(),
        "shadow" | "shadow-md" => s.shadow_md(),
        "shadow-lg" => s.shadow_lg(),
        "text-xs" => s.text_xs(),
        "text-sm" => s.text_sm(),
        "text-base" => s.text_base(),
        "text-lg" => s.text_lg(),
        "text-xl" => s.text_xl(),
        "text-2xl" => s.text_2xl(),
        "text-3xl" => s.text_3xl(),
        "font-normal" => s.font_weight(FontWeight::NORMAL),
        "font-medium" => s.font_weight(FontWeight::MEDIUM),
        "font-semibold" => s.font_weight(FontWeight::SEMIBOLD),
        "font-bold" => s.font_weight(FontWeight::BOLD),
        "cursor-pointer" => s.cursor_pointer(),
        "cursor-default" => s.cursor_default(),
        _ => apply_parametric(s, class, theme),
    }
}

fn apply_parametric<S: Styled>(s: S, class: &str, theme: &Theme) -> S {
    if let Some(n) = class
        .strip_prefix("opacity-")
        .and_then(|n| n.parse::<f32>().ok())
    {
        return s.opacity(n / 100.);
    }
    // Percentages of the parent: `w-[40%]`, `h-[75%]`.
    for (name, horizontal) in [("w-[", true), ("h-[", false)] {
        if let Some(fraction) = class
            .strip_prefix(name)
            .and_then(|rest| rest.strip_suffix("%]"))
            .and_then(|n| n.parse::<f32>().ok())
        {
            let len = relative(fraction / 100.);
            return if horizontal { s.w(len) } else { s.h(len) };
        }
    }
    const SPACING: &[&str] = &[
        "min-w", "size", "gap", "px", "py", "pt", "pb", "pl", "pr", "mx", "my", "mt", "mb", "p",
        "m", "w", "h",
    ];
    for name in SPACING {
        if let Some(len) = class
            .strip_prefix(name)
            .and_then(|rest| rest.strip_prefix('-'))
            .and_then(spacing)
        {
            let len = px(len);
            return match *name {
                "p" => s.p(len),
                "px" => s.px(len),
                "py" => s.py(len),
                "pt" => s.pt(len),
                "pb" => s.pb(len),
                "pl" => s.pl(len),
                "pr" => s.pr(len),
                "m" => s.m(len),
                "mx" => s.mx(len),
                "my" => s.my(len),
                "mt" => s.mt(len),
                "mb" => s.mb(len),
                "gap" => s.gap(len),
                "w" => s.w(len),
                "h" => s.h(len),
                "size" => s.size(len),
                _ => s.min_w(len),
            };
        }
    }
    for name in ["bg", "text", "border"] {
        if let Some(color) = class
            .strip_prefix(name)
            .and_then(|rest| rest.strip_prefix('-'))
            .and_then(|value| color(value, theme))
        {
            return match name {
                "bg" => s.bg(color),
                "text" => s.text_color(color),
                _ => s.border_color(color),
            };
        }
    }
    unknown(s, class)
}

/// Tailwind's spacing scale in pixels: `4` is 16px, `px` is 1px, and
/// `[13px]` is exactly that.
fn spacing(value: &str) -> Option<f32> {
    if let Some(pixels) = value.strip_prefix('[').and_then(|v| v.strip_suffix("px]")) {
        return pixels.parse().ok();
    }
    match value {
        "px" => Some(1.),
        _ => value.parse::<f32>().ok().map(|n| n * 4.),
    }
}

fn color(value: &str, theme: &Theme) -> Option<Hsla> {
    let (value, alpha) = match value.rsplit_once('/') {
        Some((value, alpha)) => (value, alpha.parse::<f32>().ok()? / 100.),
        None => (value, 1.),
    };
    let rgba = match value {
        "white" => rgb(0xffffff),
        "black" => rgb(0x000000),
        "transparent" => Rgba {
            r: 0.,
            g: 0.,
            b: 0.,
            a: 0.,
        },
        _ => {
            let hex = match value.strip_prefix('[').and_then(|v| v.strip_suffix(']')) {
                Some(hex) => hex,
                None => theme.get(value)?.as_str(),
            };
            hex_color(hex)?
        }
    };
    Some(Hsla::from(rgba).opacity(alpha))
}

fn hex_color(hex: &str) -> Option<Rgba> {
    let digits = hex.strip_prefix('#')?;
    let value = u32::from_str_radix(digits, 16).ok()?;
    match digits.len() {
        6 => Some(rgb(value)),
        8 => Some(Rgba {
            r: ((value >> 24) & 0xff) as f32 / 255.,
            g: ((value >> 16) & 0xff) as f32 / 255.,
            b: ((value >> 8) & 0xff) as f32 / 255.,
            a: (value & 0xff) as f32 / 255.,
        }),
        _ => None,
    }
}

fn unknown<S>(s: S, class: &str) -> S {
    static REPORTED: Mutex<Option<HashSet<String>>> = Mutex::new(None);
    let mut reported = REPORTED.lock().unwrap();
    if reported.get_or_insert_default().insert(class.to_owned()) {
        eprintln!("baguette: unsupported class `{class}`");
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn variants_split_by_prefix() {
        let classes = "px-4 hover:opacity-90 active:bg-primary disabled:opacity-50 focus:ring";
        assert_eq!(
            for_variant(classes, Variant::Base).collect::<Vec<_>>(),
            ["px-4"]
        );
        assert_eq!(
            for_variant(classes, Variant::Hover).collect::<Vec<_>>(),
            ["opacity-90"]
        );
        assert_eq!(
            for_variant(classes, Variant::Active).collect::<Vec<_>>(),
            ["bg-primary"]
        );
        assert_eq!(
            for_variant(classes, Variant::Disabled).collect::<Vec<_>>(),
            ["opacity-50"]
        );
    }

    #[test]
    fn colors_resolve_tokens_hex_and_alpha() {
        let theme = Theme::from([("primary".into(), "#2563eb".into())]);
        assert_eq!(color("primary", &theme), Some(Hsla::from(rgb(0x2563eb))));
        assert_eq!(color("[#ff0000]", &theme), Some(Hsla::from(rgb(0xff0000))));
        assert_eq!(color("white/50", &theme).map(|c| c.a), Some(0.5));
        assert_eq!(color("missing", &theme), None);
    }

    #[test]
    fn spacing_uses_the_tailwind_scale() {
        assert_eq!(spacing("4"), Some(16.));
        assert_eq!(spacing("0.5"), Some(2.));
        assert_eq!(spacing("[13px]"), Some(13.));
        assert_eq!(spacing("px"), Some(1.));
        assert_eq!(spacing("primary"), None);
    }
}
