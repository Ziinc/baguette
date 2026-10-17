//! The view trees Elixir renders, drawn as GPUI elements.
//!
//! The host feeds every [`Frame`] it receives to a window's [`Root`], and
//! hands the [`Event`]s that root raises back to Elixir. Tests do the same
//! without the host:
//!
//! ```ignore
//! let frame: Frame = serde_json::from_str(json)?;
//! let root = cx.new(|_| Root::new(0, |event| events.borrow_mut().push(event)).with_frame(frame));
//! ```
//!
//! With the `test-support` feature every element is registered with
//! gpui-base's `.test_support()`, so gpui-testing-library finds it by role,
//! label or text.

mod style;

use std::collections::BTreeMap;
use std::rc::Rc;

use gpui::{
    AnyElement, InteractiveElement, IntoElement, ParentElement, Role, SharedString,
    StatefulInteractiveElement, Styled, prelude::FluentBuilder,
};
use serde::{Deserialize, Serialize};

pub use crate::style::Theme;
use crate::style::Variant;

/// One render from Elixir: the theme tokens and the root node.
#[derive(Deserialize, Default, Debug, Clone)]
pub struct Frame {
    #[serde(default)]
    pub theme: Theme,
    pub root: Option<Node>,
}

/// A node of the tree: text, or `{"t": tag, "a": attrs, "c": children}`.
#[derive(Deserialize, Debug, Clone)]
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

/// A UI event for the Elixir view that owns `window`, serialized in the shape
/// `Baguette.Host` routes (`{"type": "click", "window": 0, ...}`).
#[derive(Serialize, Debug, Clone, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    /// An element with `phx-click` was clicked; `values` are its
    /// `phx-value-*` attributes without the prefix.
    Click {
        window: u32,
        event: String,
        values: BTreeMap<String, String>,
    },
}

type EventHandler = Rc<dyn Fn(Event)>;

/// Everything rendering one window's tree needs.
struct Scope<'a> {
    window: u32,
    theme: &'a Theme,
    on_event: &'a EventHandler,
}

fn render(node: &Node, path: &str, scope: &Scope) -> AnyElement {
    match node {
        Node::Text(text) => SharedString::from(text.clone()).into_any_element(),
        Node::Element {
            tag,
            attrs,
            children,
        } => render_element(tag, attrs, children, path, scope),
    }
}

fn render_element(
    tag: &str,
    attrs: &BTreeMap<String, String>,
    children: &[Node],
    path: &str,
    scope: &Scope,
) -> AnyElement {
    let theme = scope.theme;
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
        .map(|(i, child)| render(child, &format!("{path}.{i}"), scope));

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
        .when_some(accessible_name(tag, attrs, children), |el, label| {
            el.aria_label(SharedString::from(label))
        });

    if disabled {
        return observed(Disabled(element));
    }
    let Some(on_click) = click_handler(scope, attrs) else {
        return observed(element);
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
    observed(
        element
            .hover(move |s| style::apply(s, hover.iter(), &hover_theme))
            .active(move |s| style::apply(s, active.iter(), &active_theme))
            .on_click(on_click),
    )
}

/// With `test-support`, registers `element` for gpui-testing-library queries.
fn observed<E>(element: E) -> AnyElement
where
    E: gpui::Element<PrepaintState = Option<gpui::Hitbox>> + InteractiveElement,
{
    #[cfg(feature = "test-support")]
    return gpui_base::TestSupportExt::test_support(element).into_any_element();
    #[cfg(not(feature = "test-support"))]
    element.into_any_element()
}

/// Reports its element as disabled to screen readers and test queries; GPUI's
/// `div` has no builder for AccessKit's disabled flag.
struct Disabled<E>(E);

impl<E: gpui::Element> IntoElement for Disabled<E> {
    type Element = Self;

    fn into_element(self) -> Self {
        self
    }
}

impl<E: InteractiveElement> InteractiveElement for Disabled<E> {
    fn interactivity(&mut self) -> &mut gpui::Interactivity {
        self.0.interactivity()
    }
}

impl<E: gpui::Element> gpui::Element for Disabled<E> {
    type RequestLayoutState = E::RequestLayoutState;
    type PrepaintState = E::PrepaintState;

    fn id(&self) -> Option<gpui::ElementId> {
        self.0.id()
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        self.0.source_location()
    }

    fn request_layout(
        &mut self,
        id: Option<&gpui::GlobalElementId>,
        inspector_id: Option<&gpui::InspectorElementId>,
        window: &mut gpui::Window,
        cx: &mut gpui::App,
    ) -> (gpui::LayoutId, Self::RequestLayoutState) {
        self.0.request_layout(id, inspector_id, window, cx)
    }

    fn prepaint(
        &mut self,
        id: Option<&gpui::GlobalElementId>,
        inspector_id: Option<&gpui::InspectorElementId>,
        bounds: gpui::Bounds<gpui::Pixels>,
        request_layout: &mut Self::RequestLayoutState,
        window: &mut gpui::Window,
        cx: &mut gpui::App,
    ) -> Self::PrepaintState {
        self.0
            .prepaint(id, inspector_id, bounds, request_layout, window, cx)
    }

    fn paint(
        &mut self,
        id: Option<&gpui::GlobalElementId>,
        inspector_id: Option<&gpui::InspectorElementId>,
        bounds: gpui::Bounds<gpui::Pixels>,
        request_layout: &mut Self::RequestLayoutState,
        prepaint: &mut Self::PrepaintState,
        window: &mut gpui::Window,
        cx: &mut gpui::App,
    ) {
        self.0.paint(
            id,
            inspector_id,
            bounds,
            request_layout,
            prepaint,
            window,
            cx,
        )
    }

    fn a11y_role(&self) -> Option<gpui::accesskit::Role> {
        self.0.a11y_role()
    }

    fn write_a11y_info(&self, node: &mut gpui::accesskit::Node) {
        self.0.write_a11y_info(node);
        node.set_disabled();
    }

    fn a11y_synthetic_children(
        &mut self,
        prepaint: &mut Self::PrepaintState,
        builder: &mut gpui::A11ySubtreeBuilder,
    ) {
        self.0.a11y_synthetic_children(prepaint, builder)
    }
}

/// An element's `aria-label`, or for a button its text, as a browser names a
/// button from its content.
fn accessible_name(
    tag: &str,
    attrs: &BTreeMap<String, String>,
    children: &[Node],
) -> Option<String> {
    match attrs.get("aria-label") {
        Some(label) => Some(label.clone()),
        None if tag == "button" => Some(text_of(children)).filter(|text| !text.is_empty()),
        None => None,
    }
}

/// What clicking an element with `phx-click` does: raise an [`Event::Click`]
/// with its `phx-value-*` attributes for the view that owns the window.
fn click_handler(
    scope: &Scope,
    attrs: &BTreeMap<String, String>,
) -> Option<impl Fn(&gpui::ClickEvent, &mut gpui::Window, &mut gpui::App) + 'static> {
    let window = scope.window;
    let on_event = scope.on_event.clone();
    let event = attrs.get("phx-click")?.clone();
    let values: BTreeMap<String, String> = attrs
        .iter()
        .filter_map(|(key, value)| {
            Some((key.strip_prefix("phx-value-")?.to_owned(), value.clone()))
        })
        .collect();
    Some(
        move |_: &gpui::ClickEvent, _: &mut gpui::Window, _: &mut gpui::App| {
            on_event(Event::Click {
                window,
                event: event.clone(),
                values: values.clone(),
            });
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
                log::info!("baguette: bounds {label} {} {}", at.0, at.1);
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
    window: u32,
    frame: Frame,
    on_event: EventHandler,
}

impl Root {
    /// An empty root for `window`, raising its UI events to `on_event`.
    pub fn new(window: u32, on_event: impl Fn(Event) + 'static) -> Self {
        Self {
            window,
            frame: Frame::default(),
            on_event: Rc::new(on_event),
        }
    }

    /// Starts from `frame` instead of an empty tree.
    pub fn with_frame(mut self, frame: Frame) -> Self {
        self.frame = frame;
        self
    }

    /// Replaces the tree; call `cx.notify()` to redraw.
    pub fn set_frame(&mut self, frame: Frame) {
        self.frame = frame;
    }

    pub fn window(&self) -> u32 {
        self.window
    }

    pub fn frame(&self) -> &Frame {
        &self.frame
    }
}

impl gpui::Render for Root {
    fn render(&mut self, _: &mut gpui::Window, _: &mut gpui::Context<Self>) -> impl IntoElement {
        let scope = Scope {
            window: self.window,
            theme: &self.frame.theme,
            on_event: &self.on_event,
        };
        let content = self
            .frame
            .root
            .as_ref()
            .map(|node| render(node, "root", &scope));
        gpui::div().size_full().children(content)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn click_events_serialize_as_elixir_routes_them() {
        let event = Event::Click {
            window: 2,
            event: "inc".into(),
            values: [("by".into(), "1".into())].into(),
        };
        assert_eq!(
            serde_json::to_value(event).unwrap(),
            serde_json::json!({"type": "click", "window": 2, "event": "inc", "values": {"by": "1"}})
        );
    }
}
