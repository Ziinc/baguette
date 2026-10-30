//! Keymaps from Elixir (`keymap` in `Baguette.View`) as GPUI key bindings,
//! and the one action type they all dispatch.

use std::rc::Rc;

use serde::Deserialize;
use tauri_plugin_gpui::gpui::{
    self, Action, KeyBinding, KeyBindingContextPredicate, PlatformKeyboardMapper, SharedString,
};

/// A binding as a frame carries it.
#[derive(Deserialize, Clone, Debug, PartialEq, Eq, Hash)]
pub struct Binding {
    pub keys: String,
    pub action: String,
    #[serde(default)]
    pub context: Option<String>,
}

/// An action of the view's, named as Elixir names it. GPUI dispatches it
/// like any other; the host sends its name back.
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct ElixirAction {
    pub name: SharedString,
}

impl Action for ElixirAction {
    fn boxed_clone(&self) -> Box<dyn Action> {
        Box::new(self.clone())
    }

    fn partial_eq(&self, action: &dyn Action) -> bool {
        (action as &dyn std::any::Any)
            .downcast_ref::<Self>()
            .is_some_and(|other| other == self)
    }

    fn name(&self) -> &'static str {
        Self::name_for_type()
    }

    fn name_for_type() -> &'static str {
        "baguette::ElixirAction"
    }

    fn build(value: serde_json::Value) -> gpui::Result<Box<dyn Action>> {
        Ok(Box::new(serde_json::from_value::<Self>(value)?))
    }
}

/// `binding` as a GPUI key binding, or why it can't be one.
pub fn key_binding(
    binding: &Binding,
    mapper: &dyn PlatformKeyboardMapper,
) -> Result<KeyBinding, String> {
    if binding.keys.trim().is_empty() {
        return Err(format!("`{}` has no keys", binding.action));
    }
    let context = match &binding.context {
        Some(context) => Some(Rc::new(
            KeyBindingContextPredicate::parse(context).map_err(|e| e.to_string())?,
        )),
        None => None,
    };
    let action = ElixirAction {
        name: binding.action.clone().into(),
    };
    KeyBinding::load(
        &binding.keys,
        Box::new(action),
        context,
        false,
        None,
        mapper,
    )
    .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tauri_plugin_gpui::gpui::DummyKeyboardMapper;

    fn binding(keys: &str, context: Option<&str>) -> Binding {
        Binding {
            keys: keys.into(),
            action: "open_palette".into(),
            context: context.map(Into::into),
        }
    }

    #[test]
    fn binds_keys_to_named_actions() {
        let key = key_binding(&binding("secondary-k", Some("Jobs")), &DummyKeyboardMapper).unwrap();
        let expected = ElixirAction {
            name: "open_palette".into(),
        };
        assert!(key.action().partial_eq(&expected));
        assert!(key.predicate().is_some());
        assert!(key_binding(&binding("escape", None), &DummyKeyboardMapper).is_ok());
    }

    #[test]
    fn rejects_what_gpui_cant_parse() {
        assert!(key_binding(&binding("", None), &DummyKeyboardMapper).is_err());
        assert!(key_binding(&binding("k", Some("Jobs &&")), &DummyKeyboardMapper).is_err());
    }

    #[test]
    fn actions_compare_by_name() {
        let a = ElixirAction { name: "a".into() };
        assert!(a.partial_eq(&ElixirAction { name: "a".into() }));
        assert!(!a.partial_eq(&ElixirAction { name: "b".into() }));
        let built = ElixirAction::build(serde_json::json!({"name": "a"})).unwrap();
        assert!(built.partial_eq(&a));
    }
}
