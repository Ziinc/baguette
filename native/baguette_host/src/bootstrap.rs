//! gpui-bootstrap's components as `bs-*` elements.
//!
//! Elixir writes `<bs-button variant="success" phx-click="save">Save</bs-button>`
//! and the host renders gpui-bootstrap's `Button`, so an app gets Bootstrap's
//! look and gpui-kit's focus and keyboard behaviour without writing Rust.
//! Attributes mirror the builders (`variant`, `outline`, `size`, `pill`, ...),
//! `class` still applies on top, and `phx-click` works as on any element.

use std::collections::BTreeMap;

use gpui_bootstrap::prelude::*;
use tauri_plugin_gpui::gpui::{
    AnyElement, IntoElement, ParentElement, SharedString, Styled, prelude::FluentBuilder,
};

use crate::style::{self, Theme, Variant as ClassVariant};
use crate::view::{self, Node, click_handler, text_of};

/// Renders `tag` if it names a component, or returns `None`.
pub fn render(
    tag: &str,
    attrs: &BTreeMap<String, String>,
    children: &[Node],
    path: &str,
    window: u32,
    theme: &Theme,
) -> Option<AnyElement> {
    let id = SharedString::from(path.to_owned());
    let classes = attrs.get("class").map(String::as_str).unwrap_or("");
    let rendered = || -> Vec<AnyElement> {
        children
            .iter()
            .enumerate()
            .map(|(i, child)| view::render(child, &format!("{path}.{i}"), window, theme))
            .collect()
    };
    let flag = |name: &str| attrs.get(name).is_some_and(|v| v != "false");
    let variant = attrs.get("variant").and_then(|v| variant(v));
    let size = attrs.get("size").and_then(|s| match s.as_str() {
        "sm" => Some(Size::Small),
        "lg" => Some(Size::Large),
        _ => None,
    });
    let styled = Classes { classes, theme };
    let number = |name: &str| attrs.get(name).and_then(|v| v.parse::<f32>().ok());

    let element = match tag {
        "bs-button" => {
            let button = Button::new(id)
                .label(text_of(children))
                .when_some(variant, Button::variant)
                .when(flag("outline"), Button::outline)
                .when(flag("link"), Button::link)
                .when_some(size, Button::with_size)
                .disabled(flag("disabled"))
                .active(flag("active"))
                .when_some(attrs.get("aria-label"), |b, l| {
                    b.accessibility_label(l.clone())
                })
                .when_some(click_handler(window, attrs), Button::on_click);
            styled.on(button).into_any_element()
        }
        "bs-badge" => styled
            .on(Badge::new(text_of(children))
                .when_some(variant, Badge::variant)
                .pill(flag("pill"))
                .subtle(flag("subtle")))
            .into_any_element(),
        "bs-alert" => styled
            .on(Alert::new(id)
                .when_some(variant, Alert::variant)
                .when_some(attrs.get("heading"), |a, h| a.heading(h.clone()))
                .when_some(click_handler(window, attrs), Alert::on_dismiss)
                .children(rendered()))
            .into_any_element(),
        "bs-card" => styled
            .on(Card::new()
                .when_some(attrs.get("title"), |c, t| c.title(t.clone()))
                .when_some(attrs.get("subtitle"), |c, t| c.subtitle(t.clone()))
                .when_some(variant, Card::border_variant)
                .children(rendered()))
            .into_any_element(),
        "bs-progress" => {
            let mut bar = ProgressBar::new(number("value").unwrap_or(0.0));
            if let Some(variant) = variant {
                bar = bar.variant(variant);
            }
            if let Some(label) = attrs.get("label") {
                bar = bar.label(label.clone());
            }
            styled
                .on(Progress::new(id)
                    .bar(bar)
                    .when_some(attrs.get("aria-label"), |p, l| {
                        p.accessibility_label(l.clone())
                    }))
                .into_any_element()
        }
        "bs-spinner" => styled
            .on(Spinner::new()
                .when(flag("grow"), Spinner::grow)
                .when_some(variant, Spinner::variant)
                .when_some(size, Spinner::with_size))
            .into_any_element(),
        "bs-list-group" => {
            let items = children
                .iter()
                .enumerate()
                .filter_map(|(i, child)| match child {
                    Node::Element {
                        tag,
                        attrs,
                        children,
                    } if tag == "bs-list-item" => Some(list_item(
                        attrs,
                        children,
                        &format!("{path}.{i}"),
                        window,
                        theme,
                    )),
                    _ => None,
                });
            styled
                .on(ListGroup::new(id).items(items).flush(flag("flush")))
                .into_any_element()
        }
        "bs-heading" => {
            let level = attrs.get("level").and_then(|l| l.parse().ok()).unwrap_or(2);
            Heading::new(level, text_of(children)).into_any_element()
        }
        "bs-lead" => Lead::new(text_of(children)).into_any_element(),
        "bs-muted" => Muted::new(text_of(children)).into_any_element(),
        _ => return None,
    };
    Some(element)
}

/// An element's `class` utilities, applied on top of a component's own style.
struct Classes<'a> {
    classes: &'a str,
    theme: &'a Theme,
}

impl Classes<'_> {
    fn on<S: Styled>(&self, element: S) -> S {
        style::apply(
            element,
            style::for_variant(self.classes, ClassVariant::Base),
            self.theme,
        )
    }
}

fn list_item(
    attrs: &BTreeMap<String, String>,
    children: &[Node],
    path: &str,
    window: u32,
    theme: &Theme,
) -> ListGroupItem {
    let flag = |name: &str| attrs.get(name).is_some_and(|v| v != "false");
    let classes = attrs.get("class").map(String::as_str).unwrap_or("");
    let item = ListGroupItem::new(SharedString::from(path.to_owned()))
        .when_some(
            attrs.get("variant").and_then(|v| variant(v)),
            ListGroupItem::variant,
        )
        .active(flag("active"))
        .disabled(flag("disabled"))
        .when_some(click_handler(window, attrs), ListGroupItem::on_click)
        .children(
            children
                .iter()
                .enumerate()
                .map(|(i, child)| view::render(child, &format!("{path}.{i}"), window, theme)),
        );
    style::apply(item, style::for_variant(classes, ClassVariant::Base), theme)
}

fn variant(name: &str) -> Option<gpui_bootstrap::Variant> {
    use gpui_bootstrap::Variant::*;
    Some(match name {
        "primary" => Primary,
        "secondary" => Secondary,
        "success" => Success,
        "info" => Info,
        "warning" => Warning,
        "danger" => Danger,
        "light" => Light,
        "dark" => Dark,
        _ => return None,
    })
}
