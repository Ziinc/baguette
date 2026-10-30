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

/// With the `playwright` feature, registers an element with gpui-kit so
/// Playwright's locators find it by its role and label.
macro_rules! observed {
    ($element:expr) => {{
        #[cfg(feature = "playwright")]
        {
            use gpui_kit::base::TestSupportExt;
            $element.test_support().into_any_element()
        }
        #[cfg(not(feature = "playwright"))]
        {
            $element.into_any_element()
        }
    }};
}

pub fn render(node: &Node, path: &str, window: u32, theme: &Theme) -> AnyElement {
    match node {
        #[cfg(feature = "playwright")]
        Node::Text(text) => {
            use gpui_kit::base::TestTextExt;
            SharedString::from(text.clone())
                .test_text(text.clone())
                .into_any_element()
        }
        #[cfg(not(feature = "playwright"))]
        Node::Text(text) => SharedString::from(text.clone()).into_any_element(),
        Node::Element { tag, attrs, .. } if tag == "line" => render_line(attrs, theme),
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

    let element = match attrs.get("phx-drag").filter(|_| !disabled) {
        Some(event) => {
            let (up, up_out) = drag_handlers(window, path, event, attrs);
            let key = path.to_owned();
            element
                .on_mouse_down(gpui::MouseButton::Left, move |e, _, _| {
                    DRAGS.with(|d| d.borrow_mut().insert(key.clone(), e.position));
                })
                .on_mouse_up(gpui::MouseButton::Left, up)
                .on_mouse_up_out(gpui::MouseButton::Left, up_out)
        }
        None => element,
    };

    let Some(on_click) = click_handler(window, attrs).filter(|_| !disabled) else {
        return observed!(element);
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
    observed!(
        element
            .hover(move |s| style::apply(s, hover.iter(), &hover_theme))
            .active(move |s| style::apply(s, active.iter(), &active_theme))
            .on_click(on_click)
    )
}

thread_local! {
    /// Where the pointer went down on each `phx-drag` element still held,
    /// by element path.
    static DRAGS: std::cell::RefCell<std::collections::HashMap<String, gpui::Point<gpui::Pixels>>> =
        Default::default();
}

type MouseUp = Box<dyn Fn(&gpui::MouseUpEvent, &mut gpui::Window, &mut gpui::App)>;

/// What releasing a `phx-drag` element does, over it or anywhere else:
/// send the event, its `phx-value-*` attributes and how far the pointer
/// moved (`dx`, `dy`) to the view that owns `window`.
fn drag_handlers(
    window: u32,
    path: &str,
    event: &str,
    attrs: &BTreeMap<String, String>,
) -> (MouseUp, MouseUp) {
    let release = {
        let (path, event, values) = (path.to_owned(), event.to_owned(), values_of(attrs));
        move |e: &gpui::MouseUpEvent, _: &mut gpui::Window, _: &mut gpui::App| {
            let Some(start) = DRAGS.with(|d| d.borrow_mut().remove(&path)) else {
                return;
            };
            bridge::emit(&serde_json::json!({
                "type": "drag",
                "window": window,
                "event": event,
                "values": values,
                "dx": f32::from(e.position.x - start.x),
                "dy": f32::from(e.position.y - start.y),
            }));
        }
    };
    let release = std::rc::Rc::new(release);
    let other = release.clone();
    (
        Box::new(move |e, w, cx| release(e, w, cx)),
        Box::new(move |e, w, cx| other(e, w, cx)),
    )
}

/// A straight line from `x1`,`y1` to `x2`,`y2`, in pixels from the parent's
/// top left; `stroke-<color>` and `stroke-width` style it.
fn render_line(attrs: &BTreeMap<String, String>, theme: &Theme) -> AnyElement {
    let at = |key: &str| {
        attrs
            .get(key)
            .and_then(|v| v.parse::<f32>().ok())
            .unwrap_or(0.)
    };
    let (x1, y1, x2, y2) = (at("x1"), at("y1"), at("x2"), at("y2"));
    let width = attrs
        .get("stroke-width")
        .and_then(|v| v.parse::<f32>().ok())
        .unwrap_or(2.);
    let color = attrs
        .get("class")
        .into_iter()
        .flat_map(|c| c.split_whitespace())
        .find_map(|c| style::color(c.strip_prefix("stroke-")?, theme))
        .unwrap_or_else(|| gpui::black().into());
    gpui::canvas(
        |_, _, _| {},
        move |bounds, _, window, _| {
            let origin = bounds.origin;
            let mut path = gpui::PathBuilder::stroke(gpui::px(width));
            path.move_to(origin + gpui::point(gpui::px(x1), gpui::px(y1)));
            path.line_to(origin + gpui::point(gpui::px(x2), gpui::px(y2)));
            if let Ok(path) = path.build() {
                window.paint_path(path, color);
            }
        },
    )
    .absolute()
    .top_0()
    .left_0()
    .size_full()
    .into_any_element()
}

fn values_of(attrs: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    attrs
        .iter()
        .filter_map(|(key, value)| {
            Some((key.strip_prefix("phx-value-")?.to_owned(), value.clone()))
        })
        .collect()
}

/// What clicking an element with `phx-click` does: send the event and its
/// `phx-value-*` attributes to the view that owns `window`.
pub fn click_handler(
    window: u32,
    attrs: &BTreeMap<String, String>,
) -> Option<impl Fn(&gpui::ClickEvent, &mut gpui::Window, &mut gpui::App) + 'static> {
    let event = attrs.get("phx-click")?.clone();
    let values = values_of(attrs);
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
