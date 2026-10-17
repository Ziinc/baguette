//! The JSON view tree Elixir sends, and its rendering into GPUI elements.

use std::collections::BTreeMap;

use serde::Deserialize;
use tauri_plugin_gpui::gpui::{
    self, AnyElement, InteractiveElement, IntoElement, ParentElement, Role, SharedString,
    StatefulInteractiveElement, Styled, prelude::FluentBuilder,
};

use crate::bridge;
use crate::style::{self, Theme, Variant};

/// One render from Elixir: the theme tokens and the root node.
#[derive(Deserialize, Default)]
pub struct Frame {
    #[serde(default)]
    pub theme: Theme,
    pub root: Option<Node>,
}

#[derive(Deserialize)]
#[serde(untagged)]
pub enum Node {
    Text(String),
    Element {
        #[serde(rename = "t")]
        tag: String,
        #[serde(rename = "a", default)]
        attrs: BTreeMap<String, String>,
        #[serde(rename = "c", default)]
        children: Vec<Node>,
    },
}

pub fn render(node: &Node, path: &str, window: u32, theme: &Theme) -> AnyElement {
    match node {
        Node::Text(text) => observe_text(SharedString::from(text.clone())),
        Node::Element {
            tag,
            attrs,
            children,
        } => render_element(tag, attrs, children, path, window, theme),
    }
}

fn render_element(
    tag: &str,
    attrs: &BTreeMap<String, String>,
    children: &[Node],
    path: &str,
    window: u32,
    theme: &Theme,
) -> AnyElement {
    let classes = attrs.get("class").map(String::as_str).unwrap_or("");
    let disabled = attrs.contains_key("disabled");
    let base = style::apply(
        gpui::div(),
        style::for_variant(classes, Variant::Base),
        theme,
    );
    let base = if disabled {
        style::apply(base, style::for_variant(classes, Variant::Disabled), theme)
    } else {
        base
    };
    let rendered = children
        .iter()
        .enumerate()
        .map(|(i, child)| render(child, &format!("{path}.{i}"), window, theme));

    let element = observe(base.id(SharedString::from(path.to_owned())))
        .children(rendered)
        .when(tag == "button", |el| el.role(Role::Button))
        // A label's text is its value in AccessKit, so screen readers (and
        // the AT-SPI end-to-end test) read what a `<text>` shows.
        .when(tag == "text", |el| {
            el.role(Role::Label)
                .aria_value(SharedString::from(text_of(children)))
        })
        .when_some(attrs.get("aria-label"), |el, label| {
            el.aria_label(SharedString::from(label.clone()))
        });

    let Some(on_click) = click_handler(window, attrs).filter(|_| !disabled) else {
        return element.into_any_element();
    };
    #[cfg(target_os = "android")]
    let element = element.when_some(attrs.get("aria-label"), |el, label| {
        el.child(report_bounds(label.clone()))
    });
    let hover: Vec<String> = style::for_variant(classes, Variant::Hover)
        .map(str::to_owned)
        .collect();
    let active: Vec<String> = style::for_variant(classes, Variant::Active)
        .map(str::to_owned)
        .collect();
    let (hover_theme, active_theme) = (theme.clone(), theme.clone());
    element
        .hover(move |s| style::apply(s, hover.iter(), &hover_theme))
        .active(move |s| style::apply(s, active.iter(), &active_theme))
        .on_click(on_click)
        .into_any_element()
}

/// With the `playwright` feature, registers the element for Playwright's
/// locators: its role, label and value come from the accessibility calls below.
#[cfg(feature = "playwright")]
fn observe(
    element: gpui::Stateful<gpui::Div>,
) -> gpui_kit::base::ObservedElement<gpui::Stateful<gpui::Div>> {
    use gpui_kit::base::TestSupportExt;
    element.test_support()
}
#[cfg(not(feature = "playwright"))]
fn observe(element: gpui::Stateful<gpui::Div>) -> gpui::Stateful<gpui::Div> {
    element
}

/// Text as Playwright's `getByText` sees it, with the `playwright` feature.
fn observe_text(text: SharedString) -> AnyElement {
    #[cfg(feature = "playwright")]
    {
        use gpui_kit::base::TestTextExt;
        text.clone().test_text(text).into_any_element()
    }
    #[cfg(not(feature = "playwright"))]
    text.into_any_element()
}

/// What clicking an element with `phx-click` does: send the event and its
/// `phx-value-*` attributes to the view that owns `window`.
pub fn click_handler(
    window: u32,
    attrs: &BTreeMap<String, String>,
) -> Option<impl Fn(&gpui::ClickEvent, &mut gpui::Window, &mut gpui::App) + 'static> {
    let event = attrs.get("phx-click")?.clone();
    let values: BTreeMap<String, String> = attrs
        .iter()
        .filter_map(|(key, value)| {
            Some((key.strip_prefix("phx-value-")?.to_owned(), value.clone()))
        })
        .collect();
    Some(
        move |_: &gpui::ClickEvent, _: &mut gpui::Window, _: &mut gpui::App| {
            bridge::emit(&serde_json::json!({
                "type": "click",
                "window": window,
                "event": event,
                "values": values,
            }));
        },
    )
}

/// Logs where a labelled control is on screen, in device pixels, whenever
/// that changes: `adb shell input tap` needs them, as the Android smoke test
/// has no accessibility tree to find controls by.
#[cfg(target_os = "android")]
fn report_bounds(label: String) -> impl IntoElement {
    use std::collections::HashMap;
    use std::sync::Mutex;
    static REPORTED: Mutex<Option<HashMap<String, (i32, i32)>>> = Mutex::new(None);
    gpui::canvas(
        move |bounds, window, _| {
            let scale = window.scale_factor();
            let center = bounds.center();
            let at = (
                (f32::from(center.x) * scale) as i32,
                (f32::from(center.y) * scale) as i32,
            );
            let mut reported = REPORTED.lock().unwrap();
            if reported.get_or_insert_default().insert(label.clone(), at) != Some(at) {
                crate::log_line(&format!("baguette: bounds {label} {} {}", at.0, at.1));
            }
        },
        |_, _, _, _| {},
    )
    // Pinned to the control's corner: unpinned, an absolute child sits where
    // it would have flowed, after the label.
    .absolute()
    .top_0()
    .left_0()
    .size_full()
}

/// The text inside `nodes`, as one string.
pub fn text_of(nodes: &[Node]) -> String {
    let mut parts = Vec::new();
    for node in nodes {
        match node {
            Node::Text(text) => parts.push(text.clone()),
            Node::Element { children, .. } => parts.push(text_of(children)),
        }
    }
    parts.join(" ")
}

/// The root view of a Baguette window: whatever Elixir last rendered.
pub struct Root {
    pub window: u32,
    pub frame: Frame,
}

impl gpui::Render for Root {
    fn render(&mut self, _: &mut gpui::Window, _: &mut gpui::Context<Self>) -> impl IntoElement {
        let content = self
            .frame
            .root
            .as_ref()
            .map(|node| render(node, "root", self.window, &self.frame.theme));
        gpui::div().size_full().children(content)
    }
}
