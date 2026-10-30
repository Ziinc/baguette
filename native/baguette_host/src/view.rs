//! The JSON view tree Elixir sends, and its rendering into GPUI elements.

use std::collections::{BTreeMap, HashMap, HashSet};

use gpui_kit::component::{
    checkbox::Checkbox,
    input::{Input, InputEvent, InputState},
    tooltip::Tooltip,
};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use tauri_plugin_gpui::gpui::{
    self, AnyElement, AppContext, Entity, InteractiveElement, IntoElement, ParentElement, Role,
    SharedString, StatefulInteractiveElement, Styled, Subscription, Toggled,
    prelude::FluentBuilder,
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

/// Renders one frame. Holds what rendering needs beyond the node itself:
/// the window's id and theme, the GPUI window and the root's context (to
/// keep inputs' state between frames), and the form being rendered.
struct Renderer<'a, 'c> {
    window_id: u32,
    theme: &'a Theme,
    window: &'a mut gpui::Window,
    cx: &'a mut gpui::Context<'c, Root>,
    inputs: &'a mut HashMap<String, InputSlot>,
    checks: &'a mut HashMap<String, CheckSlot>,
    forms: HashMap<String, FormInfo>,
    form: Option<String>,
    seen: HashSet<String>,
    keydowns: Vec<WindowKey>,
    resizes: Vec<WindowResize>,
}

impl Renderer<'_, '_> {
    fn render(&mut self, node: &Node, path: &str) -> AnyElement {
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
            Node::Element { tag, attrs, .. } if tag == "line" => render_line(attrs, self.theme),
            Node::Element { tag, attrs, .. } if tag == "icon" => render_icon(attrs, self.theme),
            Node::Element { tag, attrs, .. }
                if tag == "input" && attrs.get("type").map(String::as_str) == Some("checkbox") =>
            {
                self.checkbox(attrs, path)
            }
            Node::Element { tag, attrs, .. } if tag == "input" || tag == "textarea" => {
                self.input(attrs, path)
            }
            Node::Element {
                tag,
                attrs,
                children,
            } if tag == "form" => {
                self.forms.insert(
                    path.to_owned(),
                    FormInfo {
                        change: attrs.get("phx-change").cloned(),
                        submit: attrs.get("phx-submit").cloned(),
                    },
                );
                let outer = self.form.replace(path.to_owned());
                let element = self.element(tag, attrs, children, path);
                self.form = outer;
                element
            }
            Node::Element {
                tag,
                attrs,
                children,
            } => self.element(tag, attrs, children, path),
        }
    }

    fn element(
        &mut self,
        tag: &str,
        attrs: &BTreeMap<String, String>,
        children: &[Node],
        path: &str,
    ) -> AnyElement {
        let theme = self.theme;
        let window = self.window_id;
        let classes = attrs.get("class").map(String::as_str).unwrap_or("");
        let disabled = attrs.contains_key("disabled");
        if let Some(event) = attrs.get("phx-window-keydown") {
            self.keydowns.push(WindowKey {
                event: event.clone(),
                key: attrs.get("phx-key").cloned(),
                values: values_of(attrs),
            });
        }
        if let Some(event) = attrs.get("phx-window-resize") {
            self.resizes.push(WindowResize {
                event: event.clone(),
                values: values_of(attrs),
            });
        }
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
        let rendered: Vec<AnyElement> = children
            .iter()
            .enumerate()
            .map(|(i, child)| self.render(child, &format!("{path}.{i}")))
            .collect();

        let role = role_of(tag, attrs);
        let scroll = |class: &str| classes.split_whitespace().any(|c| c == class);
        let element = base
            .id(SharedString::from(path.to_owned()))
            // Scrolling needs the element's id, so it is not a plain style.
            // `-auto` scrolls too: GPUI shows no scrollbar either way.
            .when(scroll("overflow-scroll") || scroll("overflow-auto"), |el| {
                el.overflow_scroll()
            })
            .when(
                scroll("overflow-x-scroll") || scroll("overflow-x-auto"),
                |el| el.overflow_x_scroll(),
            )
            .when(
                scroll("overflow-y-scroll") || scroll("overflow-y-auto"),
                |el| el.overflow_y_scroll(),
            )
            .children(rendered)
            .when_some(role, |el, role| el.role(role))
            // A label's text is its value in AccessKit, so screen readers (and
            // the AT-SPI end-to-end test) read what a `<text>` shows.
            .when(tag == "text", |el| {
                el.aria_value(SharedString::from(text_of(children)))
            })
            // Headings, links and list items are named by their text unless
            // labelled, as on the web.
            .when(
                !attrs.contains_key("aria-label")
                    && matches!(role, Some(Role::Heading | Role::Link | Role::ListItem)),
                |el| el.aria_label(SharedString::from(text_of(children))),
            )
            .when_some(attrs.get("aria-label"), |el, label| {
                el.aria_label(SharedString::from(label.clone()))
            })
            .when_some(attrs.get("aria-checked"), |el, checked| {
                el.aria_toggled(match checked.as_str() {
                    "true" => Toggled::True,
                    "mixed" => Toggled::Mixed,
                    _ => Toggled::False,
                })
            })
            // `title` is a tooltip on hover, as in a browser.
            .when_some(attrs.get("title").cloned(), |el, title| {
                el.tooltip(move |window, cx| Tooltip::new(title.clone()).build(window, cx))
            });

        let element = match attrs.get("phx-drag").filter(|_| !disabled) {
            Some(event) => {
                let (up, up_out) = drag_handlers(window, path, event, attrs);
                let key = path.to_owned();
                element
                    // Every element under the pointer hears the press, topmost
                    // first: the topmost draggable claims it.
                    .on_mouse_down(gpui::MouseButton::Left, move |e, _, cx| {
                        DRAGS.with(|d| d.borrow_mut().insert(key.clone(), e.position));
                        cx.stop_propagation();
                    })
                    .on_mouse_up(gpui::MouseButton::Left, up)
                    .on_mouse_up_out(gpui::MouseButton::Left, up_out)
            }
            None => element,
        };

        let on_click: Option<Box<dyn Fn(&gpui::ClickEvent, &mut gpui::Window, &mut gpui::App)>> =
            match (click_handler(window, attrs), self.submits(tag, attrs)) {
                (Some(click), _) => Some(Box::new(click)),
                (None, _) if crate::pick::Pick::from_attrs(window, attrs).is_some() => {
                    let attrs = attrs.clone();
                    Some(Box::new(move |_, _, _| {
                        if let Some(pick) = crate::pick::Pick::from_attrs(window, &attrs) {
                            pick.open();
                        }
                    }))
                }
                (None, Some(form)) => {
                    let root = self.cx.entity().downgrade();
                    Some(Box::new(move |_, _, cx| {
                        let _ = root.update(cx, |root, cx| root.submit(&form, cx));
                    }))
                }
                (None, None) => None,
            };
        let Some(on_click) = on_click.filter(|_| !disabled) else {
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
                .on_click(move |e, w, cx| on_click(e, w, cx))
        )
    }

    /// The form a `<button type="submit">` without its own `phx-click`
    /// submits: the one it is in.
    fn submits(&self, tag: &str, attrs: &BTreeMap<String, String>) -> Option<String> {
        (tag == "button" && attrs.get("type").map(String::as_str) == Some("submit"))
            .then(|| self.form.clone())
            .flatten()
    }

    /// A native text input (gpui-kit's), whose state lives in the root
    /// between frames. Typed text stands until Elixir renders a different
    /// `value`, as in a browser.
    fn input(&mut self, attrs: &BTreeMap<String, String>, path: &str) -> AnyElement {
        self.seen.insert(path.to_owned());
        let value = attrs.get("value").cloned().unwrap_or_default();
        let placeholder = attrs.get("placeholder").cloned().unwrap_or_default();
        let (window, cx) = (&mut *self.window, &mut *self.cx);

        let slot = self.inputs.entry(path.to_owned()).or_insert_with(|| {
            let masked = attrs.get("type").map(String::as_str) == Some("password");
            let state = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(placeholder.clone())
                    .masked(masked)
            });
            state.update(cx, |state, cx| state.set_value(value.clone(), window, cx));
            let key = path.to_owned();
            let subscription = cx.subscribe_in(&state, window, move |root, _, event, _, cx| {
                root.on_input(&key, event, cx)
            });
            InputSlot {
                state,
                rendered: value.clone(),
                placeholder: placeholder.clone(),
                echo: true,
                name: None,
                change: None,
                form: None,
                _subscription: subscription,
            }
        });

        if slot.rendered != value {
            slot.rendered = value.clone();
            if slot.state.read(cx).value() != value.as_str() {
                slot.echo = true;
                slot.state
                    .update(cx, |state, cx| state.set_value(value, window, cx));
            }
        }
        if slot.placeholder != placeholder {
            slot.placeholder = placeholder.clone();
            slot.state.update(cx, |state, cx| {
                state.set_placeholder(placeholder, window, cx)
            });
        }
        slot.name = attrs.get("name").cloned();
        slot.change = attrs.get("phx-change").cloned();
        slot.form = self.form.clone();

        let label = attrs
            .get("aria-label")
            .or(attrs.get("placeholder"))
            .or(attrs.get("name"))
            .cloned()
            .unwrap_or_default();
        let classes = attrs.get("class").map(String::as_str).unwrap_or("");
        style::apply(
            gpui::div(),
            style::for_variant(classes, Variant::Base),
            self.theme,
        )
        .child(
            Input::new(&slot.state)
                .id(SharedString::from(format!("{path}.input")))
                .aria_label(label)
                .disabled(attrs.contains_key("disabled")),
        )
        .into_any_element()
    }

    /// A native checkbox (gpui-kit's). It shows its new state at once;
    /// Elixir's `checked` wins whenever it changes.
    fn checkbox(&mut self, attrs: &BTreeMap<String, String>, path: &str) -> AnyElement {
        self.seen.insert(path.to_owned());
        let checked = attrs.contains_key("checked");
        let slot = self.checks.entry(path.to_owned()).or_insert(CheckSlot {
            checked,
            rendered: checked,
            ..CheckSlot::default()
        });
        if slot.rendered != checked {
            slot.rendered = checked;
            slot.checked = checked;
        }
        slot.name = attrs.get("name").cloned();
        slot.click = attrs.get("phx-click").cloned();
        slot.values = values_of(attrs);
        slot.form = self.form.clone();

        let root = self.cx.entity().downgrade();
        let key = path.to_owned();
        let label = attrs
            .get("aria-label")
            .or(attrs.get("name"))
            .cloned()
            .unwrap_or_default();
        // gpui-kit components register themselves for Playwright.
        Checkbox::new(SharedString::from(path.to_owned()))
            .checked(slot.checked)
            .accessibility_label(label)
            .on_click(move |checked, _, cx| {
                let _ = root.update(cx, |root, cx| root.on_check(&key, *checked, cx));
            })
            .into_any_element()
    }
}

/// The accessibility role of an element: its `role` attribute, or what its
/// tag means on the web.
fn role_of(tag: &str, attrs: &BTreeMap<String, String>) -> Option<Role> {
    let role = attrs.get("role").map(String::as_str).unwrap_or(match tag {
        "button" => "button",
        "text" | "label" => "label",
        "ul" | "ol" => "list",
        "li" => "listitem",
        "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => "heading",
        "a" => "link",
        "img" => "img",
        "nav" => "navigation",
        "form" => "form",
        "main" => "main",
        "header" => "banner",
        "footer" => "contentinfo",
        "aside" => "complementary",
        "section" => "region",
        "article" => "article",
        "p" => "paragraph",
        "dialog" => "dialog",
        "table" => "table",
        "tr" => "row",
        "td" | "th" => "cell",
        "hr" => "separator",
        _ => return None,
    });
    Some(match role {
        "button" => Role::Button,
        "checkbox" => Role::CheckBox,
        "switch" => Role::Switch,
        "radio" => Role::RadioButton,
        "radiogroup" => Role::RadioGroup,
        "textbox" => Role::TextInput,
        "searchbox" => Role::SearchInput,
        "combobox" => Role::ComboBox,
        "listbox" => Role::ListBox,
        "option" => Role::ListBoxOption,
        "label" => Role::Label,
        "list" => Role::List,
        "listitem" => Role::ListItem,
        "heading" => Role::Heading,
        "link" => Role::Link,
        "img" | "image" => Role::Image,
        "navigation" => Role::Navigation,
        "form" => Role::Form,
        "main" => Role::Main,
        "banner" => Role::Banner,
        "contentinfo" => Role::ContentInfo,
        "complementary" => Role::Complementary,
        "region" => Role::Region,
        "article" => Role::Article,
        "paragraph" => Role::Paragraph,
        "dialog" => Role::Dialog,
        "alert" => Role::Alert,
        "status" => Role::Status,
        "tab" => Role::Tab,
        "tablist" => Role::TabList,
        "tabpanel" => Role::TabPanel,
        "menu" => Role::Menu,
        "menuitem" => Role::MenuItem,
        "toolbar" => Role::Toolbar,
        "tooltip" => Role::Tooltip,
        "progressbar" => Role::ProgressIndicator,
        "slider" => Role::Slider,
        "separator" => Role::Splitter,
        "table" => Role::Table,
        "grid" => Role::Grid,
        "row" => Role::Row,
        "cell" | "gridcell" => Role::Cell,
        "tree" => Role::Tree,
        "treeitem" => Role::TreeItem,
        "group" => Role::Group,
        "search" => Role::Search,
        _ => return None,
    })
}

thread_local! {
    /// Where the pointer went down on each `phx-drag` element still held,
    /// by element path.
    static DRAGS: std::cell::RefCell<std::collections::HashMap<String, gpui::Point<gpui::Pixels>>> =
        Default::default();
}

const DRAG_THRESHOLD: f32 = 3.;

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
            let (dx, dy) = (
                f32::from(e.position.x - start.x),
                f32::from(e.position.y - start.y),
            );
            // A press released where it started (give or take a shaky hand
            // or finger) is a click, not a drag.
            if dx.abs() < DRAG_THRESHOLD && dy.abs() < DRAG_THRESHOLD {
                return;
            }
            bridge::emit(&serde_json::json!({
                "type": "drag",
                "window": window,
                "event": event,
                "values": values,
                "dx": dx,
                "dy": dy,
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

/// A lucide icon from gpui-kit's catalog by its kebab-case name
/// (`<icon name="undo-2" class="size-4 text-primary" />`), 16px square
/// unless sized, in its `text-*` colour or else the inherited text colour.
/// An unknown name draws nothing in the same space, and is logged once.
fn render_icon(attrs: &BTreeMap<String, String>, theme: &Theme) -> AnyElement {
    let name = attrs.get("name").map(String::as_str).unwrap_or("");
    let path = icon_path(name);
    if path.is_none() {
        static REPORTED: std::sync::Mutex<Option<HashSet<String>>> = std::sync::Mutex::new(None);
        let mut reported = REPORTED.lock().unwrap();
        if reported.get_or_insert_default().insert(name.to_owned()) {
            crate::log_line(&format!("baguette: unknown icon `{name}`"));
        }
    }
    gpui::ViewElement::new(Icon {
        path,
        classes: attrs.get("class").cloned().unwrap_or_default(),
        theme: theme.clone(),
    })
    .into_any_element()
}

/// The asset path of the icon called `name`, if gpui-kit bundles it.
pub fn icon_path(name: &str) -> Option<SharedString> {
    use gpui::AssetSource;
    let valid = !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
    let path = format!("icons/{name}.svg");
    (valid && matches!(gpui_kit::assets::AllAssets.load(&path), Ok(Some(_))))
        .then(|| SharedString::from(path))
}

struct Icon {
    path: Option<SharedString>,
    classes: String,
    theme: Theme,
}

impl gpui::RenderOnce for Icon {
    fn render(self, window: &mut gpui::Window, _: &mut gpui::App) -> impl IntoElement {
        // Like `currentColor`: the parent's text colour unless a class sets one.
        let inherited = window.text_style().color;
        let svg = gpui::svg()
            .flex_shrink_0()
            .size(gpui::px(16.))
            .text_color(inherited);
        let svg = style::apply(
            svg,
            style::for_variant(&self.classes, Variant::Base),
            &self.theme,
        );
        match self.path {
            Some(path) => svg.path(path),
            None => svg,
        }
    }
}

/// A line from `x1`,`y1` to `x2`,`y2`, in pixels from the parent's top left;
/// with `curve`, an S-curve that leaves and enters horizontally.
/// `stroke-<color>` and `stroke-width` style it.
fn render_line(attrs: &BTreeMap<String, String>, theme: &Theme) -> AnyElement {
    let at = |key: &str| {
        attrs
            .get(key)
            .and_then(|v| v.parse::<f32>().ok())
            .unwrap_or(0.)
    };
    let (x1, y1, x2, y2) = (at("x1"), at("y1"), at("x2"), at("y2"));
    let curve = attrs.contains_key("curve");
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
            let at = |x: f32, y: f32| origin + gpui::point(gpui::px(x), gpui::px(y));
            let mut path = gpui::PathBuilder::stroke(gpui::px(width));
            path.move_to(at(x1, y1));
            if curve {
                // Leaves and enters horizontally, as wires between ports do.
                let bend = ((x2 - x1).abs() / 2.).max(40.);
                path.cubic_bezier_to(at(x2, y2), at(x1 + bend, y1), at(x2 - bend, y2));
            } else {
                path.line_to(at(x2, y2));
            }
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

pub fn values_of(attrs: &BTreeMap<String, String>) -> BTreeMap<String, String> {
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

/// A text input's state between frames.
struct InputSlot {
    state: Entity<InputState>,
    /// The `value` Elixir last rendered.
    rendered: String,
    placeholder: String,
    /// Set when Baguette changed the text, so that change is not sent back.
    echo: bool,
    name: Option<String>,
    change: Option<String>,
    form: Option<String>,
    _subscription: Subscription,
}

/// A checkbox's state between frames.
#[derive(Default)]
struct CheckSlot {
    checked: bool,
    /// The `checked` Elixir last rendered.
    rendered: bool,
    name: Option<String>,
    click: Option<String>,
    values: BTreeMap<String, String>,
    form: Option<String>,
}

#[derive(Default)]
struct FormInfo {
    change: Option<String>,
    submit: Option<String>,
}

/// The root view of a Baguette window: whatever Elixir last rendered, and
/// the state of the native inputs in it.
pub struct Root {
    pub window: u32,
    pub frame: Frame,
    inputs: HashMap<String, InputSlot>,
    checks: HashMap<String, CheckSlot>,
    forms: HashMap<String, FormInfo>,
    keydowns: Vec<WindowKey>,
    /// The `phx-window-resize` bindings, each with the size last sent to it.
    resizes: Vec<(WindowResize, Option<(u32, u32)>)>,
}

/// A `phx-window-resize` binding: its event and its `phx-value-*`.
#[derive(PartialEq)]
struct WindowResize {
    event: String,
    values: BTreeMap<String, String>,
}

/// A `phx-window-keydown` binding: its event, its `phx-key` filter and its
/// `phx-value-*`.
struct WindowKey {
    event: String,
    key: Option<String>,
    values: BTreeMap<String, String>,
}

/// GPUI's name for a key as the browser's `KeyboardEvent.key` names it
/// (`"Enter"`, `"ArrowUp"`, `" "`); letters stay lowercase whatever Shift
/// does. Lone modifiers have none.
pub fn key_name(key: &str) -> Option<String> {
    Some(
        match key {
            "shift" | "control" | "alt" | "platform" | "function" | "" => return None,
            "enter" => "Enter",
            "escape" => "Escape",
            "backspace" => "Backspace",
            "delete" => "Delete",
            "tab" => "Tab",
            "space" => " ",
            "up" => "ArrowUp",
            "down" => "ArrowDown",
            "left" => "ArrowLeft",
            "right" => "ArrowRight",
            "home" => "Home",
            "end" => "End",
            "pageup" => "PageUp",
            "pagedown" => "PageDown",
            "insert" => "Insert",
            key if key.len() > 1 && key.starts_with('f') && key[1..].parse::<u8>().is_ok() => {
                return Some(key.to_uppercase());
            }
            key => key,
        }
        .to_owned(),
    )
}

impl Root {
    /// Shows `frame`. When its theme tokens changed, gpui-kit's theme takes
    /// them too, so native inputs and checkboxes match the app's colours.
    pub fn show(&mut self, frame: Frame, cx: &mut gpui::Context<Self>) {
        if frame.theme != self.frame.theme {
            apply_theme(&frame.theme, cx);
        }
        self.frame = frame;
        cx.notify();
    }

    pub fn new(window: u32, frame: Frame) -> Self {
        Self {
            window,
            frame,
            inputs: HashMap::new(),
            checks: HashMap::new(),
            forms: HashMap::new(),
            keydowns: Vec::new(),
            resizes: Vec::new(),
        }
    }

    /// Sends each `phx-window-resize` binding the window's content size, in
    /// logical pixels, when it first renders and whenever the size changes.
    fn report_size(&mut self, resizes: Vec<WindowResize>, size: (u32, u32)) {
        let mut previous = std::mem::take(&mut self.resizes);
        for binding in resizes {
            let sent = previous
                .iter()
                .position(|(b, _)| *b == binding)
                .and_then(|i| previous.swap_remove(i).1);
            if sent != Some(size) {
                let mut values: Map<String, Value> = binding
                    .values
                    .iter()
                    .map(|(k, v)| (k.clone(), Value::String(v.clone())))
                    .collect();
                values.insert("width".into(), Value::from(size.0));
                values.insert("height".into(), Value::from(size.1));
                self.emit("resize", &binding.event, values);
            }
            self.resizes.push((binding, Some(size)));
        }
    }

    /// Sends each `phx-window-keydown` binding the keystroke matches. A
    /// keystroke something already handled (a text input's own Ctrl+Z, Enter
    /// in a form) sends nothing, and while a text input has focus only
    /// chords with Ctrl or Meta do, so typing never fires shortcuts.
    pub fn on_keystroke(&self, event: &gpui::KeystrokeEvent) {
        if event.action.is_some() {
            return;
        }
        let Some(key) = key_name(&event.keystroke.key) else {
            return;
        };
        let mods = &event.keystroke.modifiers;
        let typing = event.context_stack.iter().any(|c| c.contains("Input"));
        if typing && !(mods.control || mods.platform) {
            return;
        }
        for binding in &self.keydowns {
            if binding
                .key
                .as_ref()
                .is_some_and(|k| !k.eq_ignore_ascii_case(&key))
            {
                continue;
            }
            let mut values: Map<String, Value> = binding
                .values
                .iter()
                .map(|(k, v)| (k.clone(), Value::String(v.clone())))
                .collect();
            values.insert("key".into(), Value::String(key.clone()));
            values.insert("ctrl".into(), Value::Bool(mods.control));
            values.insert("shift".into(), Value::Bool(mods.shift));
            values.insert("alt".into(), Value::Bool(mods.alt));
            values.insert("meta".into(), Value::Bool(mods.platform));
            self.emit("keydown", &binding.event, values);
        }
    }

    fn emit(&self, kind: &str, event: &str, values: Map<String, Value>) {
        bridge::emit(&json!({
            "type": kind,
            "window": self.window,
            "event": event,
            "values": values,
        }));
    }

    /// Every named value in `form`: each text input's text, and "on" for
    /// each checked checkbox, as a browser submits them.
    fn form_values(&self, form: &str, cx: &gpui::App) -> Map<String, Value> {
        let mut values = Map::new();
        for slot in self.inputs.values() {
            if let (Some(name), Some(f)) = (&slot.name, &slot.form) {
                if f == form {
                    let text = slot.state.read(cx).value().to_string();
                    values.insert(name.clone(), Value::String(text));
                }
            }
        }
        for slot in self.checks.values() {
            if let (Some(name), Some(f), true) = (&slot.name, &slot.form, slot.checked) {
                if f == form {
                    values.insert(name.clone(), Value::String("on".into()));
                }
            }
        }
        values
    }

    fn submit(&self, form: &str, cx: &gpui::App) {
        if let Some(event) = self.forms.get(form).and_then(|f| f.submit.as_ref()) {
            self.emit("submit", event, self.form_values(form, cx));
        }
    }

    /// Sends the input's `phx-change`, or its form's, with `_target`.
    fn changed(
        &self,
        form: Option<&String>,
        own: Option<&String>,
        name: &str,
        value: Value,
        cx: &gpui::App,
    ) {
        let form_change = form
            .and_then(|f| self.forms.get(f))
            .and_then(|f| f.change.as_ref());
        let Some(event) = own.or(form_change) else {
            return;
        };
        let mut values = match form {
            Some(form) => self.form_values(form, cx),
            None => Map::from_iter([(name.to_owned(), value)]),
        };
        values.insert("_target".into(), Value::String(name.to_owned()));
        self.emit("change", event, values);
    }

    fn on_input(&mut self, path: &str, event: &InputEvent, cx: &mut gpui::Context<Self>) {
        let Some(slot) = self.inputs.get_mut(path) else {
            return;
        };
        match event {
            InputEvent::Change => {
                let text = slot.state.read(cx).value().to_string();
                if std::mem::take(&mut slot.echo) && text == slot.rendered {
                    return;
                }
                let (form, own) = (slot.form.clone(), slot.change.clone());
                let name = slot.name.clone().unwrap_or_else(|| "value".into());
                self.changed(form.as_ref(), own.as_ref(), &name, Value::String(text), cx);
            }
            InputEvent::PressEnter { .. } => {
                if let Some(form) = slot.form.clone() {
                    self.submit(&form, cx);
                }
            }
            _ => {}
        }
    }

    fn on_check(&mut self, path: &str, checked: bool, cx: &mut gpui::Context<Self>) {
        let Some(slot) = self.checks.get_mut(path) else {
            return;
        };
        slot.checked = checked;
        cx.notify();
        let (click, form, name) = (slot.click.clone(), slot.form.clone(), slot.name.clone());
        if let Some(event) = click {
            let mut values: Map<String, Value> = slot
                .values
                .iter()
                .map(|(k, v)| (k.clone(), Value::String(v.clone())))
                .collect();
            values.insert("checked".into(), Value::Bool(checked));
            self.emit("click", &event, values);
        }
        if let (Some(_), Some(name)) = (&form, name) {
            let value = if checked {
                Value::String("on".into())
            } else {
                Value::Null
            };
            self.changed(form.as_ref(), None, &name, value, cx);
        }
    }
}

/// Gives gpui-kit's theme the app's tokens, as ixtable brands it: into both
/// theme configs, then re-resolved with `Theme::change`, so components that
/// read derived colours (a checkbox's fill) take them too. Tokens the app
/// does not define keep gpui-kit's own colours.
fn apply_theme(tokens: &Theme, cx: &mut gpui::App) {
    use gpui_kit::component::{Theme as KitTheme, ThemeConfig};
    use std::rc::Rc;

    let brand = |config: &ThemeConfig| {
        let mut config = config.clone();
        let colors = &mut config.colors;
        let token = |name: &str| tokens.get(name).map(|v| SharedString::from(v.clone()));
        let set = |field: &mut Option<SharedString>, names: &[&str]| {
            if let Some(value) = names.iter().find_map(|name| token(name)) {
                *field = Some(value);
            }
        };
        set(&mut colors.background, &["background"]);
        set(&mut colors.popover, &["background"]);
        set(&mut colors.foreground, &["foreground"]);
        set(&mut colors.popover_foreground, &["foreground"]);
        set(&mut colors.caret, &["foreground"]);
        set(&mut colors.muted, &["muted"]);
        set(&mut colors.muted_foreground, &["muted-foreground"]);
        set(&mut colors.border, &["border"]);
        set(&mut colors.input, &["input", "border"]);
        set(&mut colors.primary, &["primary"]);
        set(&mut colors.primary_hover, &["primary-hover", "primary"]);
        set(&mut colors.primary_active, &["primary-active", "primary"]);
        set(&mut colors.primary_foreground, &["primary-foreground"]);
        set(&mut colors.ring, &["ring", "primary"]);
        set(&mut colors.list_active_border, &["primary"]);
        set(&mut colors.secondary, &["secondary"]);
        set(&mut colors.secondary_foreground, &["secondary-foreground"]);
        set(&mut colors.accent, &["accent"]);
        set(&mut colors.accent_foreground, &["accent-foreground"]);
        set(&mut colors.link, &["link"]);
        set(&mut colors.success, &["success"]);
        set(&mut colors.warning, &["warning"]);
        set(&mut colors.danger, &["danger"]);
        Rc::new(config)
    };

    KitTheme::update(cx, |theme| {
        theme.light_theme = brand(&theme.light_theme);
        theme.dark_theme = brand(&theme.dark_theme);
    });
    let mode = KitTheme::global(cx).mode;
    KitTheme::change(mode, None, cx);
    cx.refresh_windows();
}

impl gpui::Render for Root {
    fn render(
        &mut self,
        window: &mut gpui::Window,
        cx: &mut gpui::Context<Self>,
    ) -> impl IntoElement {
        let frame = std::mem::take(&mut self.frame);
        let mut inputs = std::mem::take(&mut self.inputs);
        let mut checks = std::mem::take(&mut self.checks);
        let (content, forms, seen, resizes) = {
            let mut renderer = Renderer {
                window_id: self.window,
                theme: &frame.theme,
                window,
                cx,
                inputs: &mut inputs,
                checks: &mut checks,
                forms: HashMap::new(),
                form: None,
                seen: HashSet::new(),
                keydowns: Vec::new(),
                resizes: Vec::new(),
            };
            let content = frame
                .root
                .as_ref()
                .map(|node| renderer.render(node, "root"));
            self.keydowns = renderer.keydowns;
            (content, renderer.forms, renderer.seen, renderer.resizes)
        };
        let viewport = window.viewport_size();
        let size = (
            f32::from(viewport.width).round() as u32,
            f32::from(viewport.height).round() as u32,
        );
        self.report_size(resizes, size);
        // Inputs no longer rendered drop their state.
        inputs.retain(|path, _| seen.contains(path));
        checks.retain(|path, _| seen.contains(path));
        self.inputs = inputs;
        self.checks = checks;
        self.forms = forms;
        self.frame = frame;
        gpui::div().size_full().children(content)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_take_the_browsers_names() {
        assert_eq!(key_name("z").as_deref(), Some("z"));
        assert_eq!(key_name("enter").as_deref(), Some("Enter"));
        assert_eq!(key_name("up").as_deref(), Some("ArrowUp"));
        assert_eq!(key_name("space").as_deref(), Some(" "));
        assert_eq!(key_name("f5").as_deref(), Some("F5"));
        assert_eq!(key_name("="), Some("=".into()));
        assert_eq!(key_name("shift"), None);
    }

    #[test]
    fn icons_resolve_by_kebab_case_name() {
        assert_eq!(icon_path("undo-2").as_deref(), Some("icons/undo-2.svg"));
        assert!(icon_path("zoom-in").is_some());
        assert!(icon_path("no-such-icon").is_none());
        assert!(icon_path("../Cargo").is_none());
        assert!(icon_path("").is_none());
    }

    #[test]
    fn icons_are_embedded_in_every_build() {
        // A debug build that reads them from the build machine's disk has
        // none on a phone.
        use rust_embed::RustEmbed;
        let icon = gpui_kit::assets::AllAssets::get("icons/save.svg").expect("save icon");
        assert!(matches!(icon.data, std::borrow::Cow::Borrowed(_)));
    }
}
