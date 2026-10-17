//! A tree as Elixir sends it, rendered and clicked without the host.
use std::cell::RefCell;
use std::rc::Rc;

use baguette_view::{Event, Frame, Root};
use gpui::{Modifiers, Role, TestAppContext};
use gpui_base::test_support::snapshots;

const COUNTER: &str = r##"{
  "theme": {"primary": "#2563eb"},
  "root": {"t": "div", "a": {"class": "size-full flex-col gap-2 p-4"}, "c": [
    {"t": "text", "a": {"class": "text-xl"}, "c": ["Count: 0"]},
    {"t": "button", "a": {"class": "px-4 py-2 bg-primary", "phx-click": "inc", "phx-value-by": "1"}, "c": ["+"]},
    {"t": "button", "a": {"aria-label": "Reset", "phx-click": "reset", "disabled": ""}, "c": ["0"]}
  ]}
}"##;

#[gpui::test]
fn renders_elixir_trees_for_queries(cx: &mut TestAppContext) {
    let events = Rc::new(RefCell::new(Vec::new()));
    let frame: Frame = serde_json::from_str(COUNTER).unwrap();
    let sink = events.clone();
    let (_root, cx) = cx.add_window_view(|_, _| {
        Root::new(7, move |event| sink.borrow_mut().push(event)).with_frame(frame)
    });
    cx.run_until_parked();

    let elements = cx.update(|window, _| snapshots(window));
    let label = elements
        .iter()
        .find(|el| el.role() == Some(Role::Label))
        .expect("the <text> is observed");
    assert_eq!(label.value(), Some("Count: 0"));
    let named = |name| {
        elements
            .iter()
            .find(|el| el.role() == Some(Role::Button) && el.label() == Some(name))
            .unwrap_or_else(|| panic!("a button named {name:?}"))
            .bounds()
    };
    // A button without `aria-label` is named by its text.
    let inc = named("+");
    let reset = named("Reset");
    let disabled = |name| {
        elements
            .iter()
            .find(|el| el.label() == Some(name))
            .and_then(|el| el.disabled())
    };
    assert_eq!(disabled("+"), None);
    assert_eq!(disabled("Reset"), Some(true));

    cx.simulate_click(inc.center(), Modifiers::none());
    cx.simulate_click(reset.center(), Modifiers::none());
    assert_eq!(
        *events.borrow(),
        [Event::Click {
            window: 7,
            event: "inc".into(),
            values: [("by".into(), "1".into())].into(),
        }],
        "disabled buttons raise nothing"
    );
}

#[gpui::test]
fn set_frame_replaces_the_tree(cx: &mut TestAppContext) {
    let (root, cx) = cx.add_window_view(|_, _| Root::new(0, |_| {}));
    let frame: Frame = serde_json::from_str(COUNTER).unwrap();
    root.update(cx, |root, cx| {
        root.set_frame(frame);
        cx.notify();
    });
    cx.run_until_parked();
    let labels: Vec<_> = cx.update(|window, _| {
        snapshots(window)
            .iter()
            .filter_map(|el| el.value().map(str::to_owned))
            .collect()
    });
    assert_eq!(labels, ["Count: 0"]);
}
