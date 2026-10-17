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
        Node::Text(text) => SharedString::from(text.clone()).into_any_element(),
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

    let element = base
        .id(SharedString::from(path.to_owned()))
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

    let Some(event) = attrs.get("phx-click").filter(|_| !disabled) else {
        return element.into_any_element();
    };
    let event = event.clone();
    let values: BTreeMap<String, String> = attrs
        .iter()
        .filter_map(|(key, value)| {
            Some((key.strip_prefix("phx-value-")?.to_owned(), value.clone()))
        })
        .collect();
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
        .on_click(move |_, _, _| {
            bridge::emit(&serde_json::json!({
                "type": "click",
                "window": window,
                "event": event,
                "values": values,
            }));
        })
        .into_any_element()
}

/// The text inside `nodes`, as one string.
fn text_of(nodes: &[Node]) -> String {
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
