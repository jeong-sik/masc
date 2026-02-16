//! TRPG Action Panel — player action submission and dice rolling.
//!
//! Binds DOM event listeners on `#action-panel` elements:
//! - Submit button / Enter key → POST `/api/v1/trpg/events`
//! - Dice Roll button → POST `/api/v1/trpg/dice/roll`
//!
//! Follows the same lifecycle pattern as `social_board.rs`:
//! OnEnter binds listeners, OnExit cleans up the panel DOM.

use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use crate::config;
use crate::mode::ViewerMode;

// ─── Marker Resource ────────────────────────

/// Inserted on enter, removed on exit — signals that the action panel is bound.
#[derive(Resource)]
pub struct ActionPanelBound;

// ─── OnEnter System ─────────────────────────

/// Bind DOM event listeners when entering TRPG mode.
pub fn bind_action_panel(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    {
        bind_submit_button();
        bind_enter_key();
        bind_dice_roll_button();
        clear_action_status();
        log::info!("ActionPanel: bound");
    }

    commands.insert_resource(ActionPanelBound);
}

/// Cleanup when leaving TRPG mode.
pub fn unbind_action_panel(mut commands: Commands) {
    // Clear the status text; listeners will be garbage-collected
    // when the DOM elements are removed or replaced on mode switch.
    #[cfg(target_arch = "wasm32")]
    {
        clear_action_status();
        clear_action_input();
        log::info!("ActionPanel: unbound");
    }

    commands.remove_resource::<ActionPanelBound>();
}

// ─── Event: Submit Button ───────────────────

#[cfg(target_arch = "wasm32")]
fn bind_submit_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc.get_element_by_id("action-submit-btn") else {
        log::warn!("ActionPanel: #action-submit-btn not found");
        return;
    };

    let cb = Closure::wrap(Box::new(move || {
        submit_action_from_input();
    }) as Box<dyn FnMut()>);

    let _ = btn
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));

    cb.forget();
}

// ─── Event: Enter Key on Input ──────────────

#[cfg(target_arch = "wasm32")]
fn bind_enter_key() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(input) = doc.get_element_by_id("action-input") else {
        return;
    };

    let cb = Closure::wrap(Box::new(move |event: web_sys::KeyboardEvent| {
        if event.key() == "Enter" {
            submit_action_from_input();
        }
    }) as Box<dyn FnMut(web_sys::KeyboardEvent)>);

    let _ = input
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("keydown", cb.as_ref().unchecked_ref()));

    cb.forget();
}

// ─── Event: Dice Roll Button ────────────────

#[cfg(target_arch = "wasm32")]
fn bind_dice_roll_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc.get_element_by_id("dice-roll-btn") else {
        log::warn!("ActionPanel: #dice-roll-btn not found");
        return;
    };

    let cb = Closure::wrap(Box::new(move || {
        // Guard: must have a claimed actor
        let actor_id = {
            let doc = web_sys::window().and_then(|w| w.document());
            doc.as_ref()
                .map(|d| read_claimed_actor_id(d))
                .unwrap_or_default()
        };
        if actor_id.is_empty() {
            set_action_status("Join a character first.", "status-error");
            return;
        }

        set_action_status("Rolling dice...", "");
        disable_buttons(true);

        wasm_bindgen_futures::spawn_local(async move {
            match roll_dice().await {
                Ok(text) => set_action_status(&text, "status-ok"),
                Err(e) => {
                    let msg = format!("Dice roll failed: {:?}", e);
                    log::warn!("{}", msg);
                    set_action_status(&msg, "status-error");
                }
            }
            disable_buttons(false);
        });
    }) as Box<dyn FnMut()>);

    let _ = btn
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));

    cb.forget();
}

// ─── Action Submission Logic ────────────────

#[cfg(target_arch = "wasm32")]
fn submit_action_from_input() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };

    // Guard: must have a claimed actor
    let actor_id = read_claimed_actor_id(&doc);
    if actor_id.is_empty() {
        set_action_status("Join a character first.", "status-error");
        return;
    }

    let Some(el) = doc.get_element_by_id("action-input") else {
        return;
    };
    let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() else {
        return;
    };

    let text = input.value();
    let text = text.trim().to_string();
    if text.is_empty() {
        return;
    }

    // Clear input immediately (optimistic UX)
    input.set_value("");
    set_action_status("Submitting...", "");
    disable_buttons(true);

    wasm_bindgen_futures::spawn_local(async move {
        match submit_action(&actor_id, &text).await {
            Ok(()) => set_action_status("Action submitted.", "status-ok"),
            Err(e) => {
                let msg = format!("Submit failed: {:?}", e);
                log::warn!("{}", msg);
                set_action_status(&msg, "status-error");
            }
        }
        disable_buttons(false);
    });
}

// ─── HTTP: Submit Action ────────────────────

#[cfg(target_arch = "wasm32")]
async fn submit_action(actor_id: &str, action_text: &str) -> Result<(), JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let url = format!("{}/api/v1/trpg/events", config::MASC_MCP_URL);

    // Escape for JSON string embedding
    let escaped_text = action_text
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n");
    let escaped_actor = actor_id
        .replace('\\', "\\\\")
        .replace('"', "\\\"");

    let body = format!(
        r#"{{"event_type":"turn.action.proposed","data":{{"character":"{}","action_text":"{}"}}}}"#,
        escaped_actor, escaped_text
    );

    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_mode(web_sys::RequestMode::Cors);
    opts.set_body(&JsValue::from_str(&body));

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    request.headers().set("Content-Type", "application/json")?;

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;

    if !resp.ok() {
        return Err(JsValue::from_str(&format!("HTTP {}", resp.status())));
    }

    log::info!("ActionPanel: action submitted");
    Ok(())
}

// ─── HTTP: Dice Roll ────────────────────────

#[cfg(target_arch = "wasm32")]
async fn roll_dice() -> Result<String, JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let url = format!("{}/api/v1/trpg/dice/roll", config::MASC_MCP_URL);
    let room_id = config::DEFAULT_ROOM_ID;

    let body = format!(
        r#"{{"room":"{}","dice":"1d20","reason":"Player roll"}}"#,
        room_id
    );

    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_mode(web_sys::RequestMode::Cors);
    opts.set_body(&JsValue::from_str(&body));

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    request.headers().set("Content-Type", "application/json")?;

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;

    if !resp.ok() {
        return Err(JsValue::from_str(&format!("HTTP {}", resp.status())));
    }

    // Parse response to extract the roll result for status display
    let json = JsFuture::from(resp.json()?).await?;
    let result_str = js_sys::JSON::stringify(&json)
        .map(|s| String::from(s))
        .unwrap_or_else(|_| "Roll completed.".to_string());

    // Try to extract a human-readable result
    let display = extract_roll_display(&result_str);
    log::info!("ActionPanel: dice rolled — {}", display);
    Ok(display)
}

/// Extract a short display string from the dice roll JSON response.
/// Falls back to the raw response if parsing fails.
fn extract_roll_display(json_str: &str) -> String {
    // Try to find "total":N or "result":N in the JSON
    for key in &["total", "result", "value"] {
        let pattern = format!("\"{}\":", key);
        if let Some(idx) = json_str.find(&pattern) {
            let after = &json_str[idx + pattern.len()..];
            let num_str: String = after
                .chars()
                .take_while(|c| c.is_ascii_digit() || *c == '-')
                .collect();
            if !num_str.is_empty() {
                return format!("Rolled: {}", num_str);
            }
        }
    }
    "Roll completed.".to_string()
}

// ─── DOM Helpers ────────────────────────────

#[cfg(target_arch = "wasm32")]
fn set_action_status(msg: &str, class: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(el) = doc.get_element_by_id("action-status") else {
        return;
    };
    el.set_text_content(Some(msg));
    // Reset classes, then add the specified one
    el.set_class_name(if class.is_empty() { "" } else { class });
}

#[cfg(target_arch = "wasm32")]
fn clear_action_status() {
    set_action_status("", "");
}

#[cfg(target_arch = "wasm32")]
fn clear_action_input() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    if let Some(el) = doc.get_element_by_id("action-input") {
        if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
            input.set_value("");
        }
    }
}

/// Read the claimed actor ID from the hidden input set by actor_join.rs.
#[cfg(target_arch = "wasm32")]
fn read_claimed_actor_id(doc: &web_sys::Document) -> String {
    doc.get_element_by_id("claimed-actor-id")
        .and_then(|el| el.dyn_ref::<web_sys::HtmlInputElement>().map(|i| i.value()))
        .unwrap_or_default()
}

#[cfg(target_arch = "wasm32")]
fn disable_buttons(disabled: bool) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    for id in &["action-submit-btn", "dice-roll-btn"] {
        if let Some(el) = doc.get_element_by_id(id) {
            if let Some(btn) = el.dyn_ref::<web_sys::HtmlButtonElement>() {
                btn.set_disabled(disabled);
            }
        }
    }
}

// ─── Bevy System: Visibility Sync ───────────

/// Hides the action panel when not in TRPG mode.
/// The panel HTML always exists in index.html but should only be visible in TRPG.
pub fn sync_action_panel_visibility(mode: Res<State<ViewerMode>>) {
    let _ = mode; // read to register as system parameter

    #[cfg(target_arch = "wasm32")]
    {
        let visible = matches!(mode.get(), ViewerMode::Trpg);
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        if let Some(el) = doc.get_element_by_id("action-panel") {
            if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
                let _ = html_el
                    .style()
                    .set_property("display", if visible { "block" } else { "none" });
            }
        }
    }
}

// ─── Tests ──────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_roll_display_with_total() {
        let json = r#"{"dice":"1d20","total":17,"rolls":[17]}"#;
        assert_eq!(extract_roll_display(json), "Rolled: 17");
    }

    #[test]
    fn extract_roll_display_with_result() {
        let json = r#"{"result":4}"#;
        assert_eq!(extract_roll_display(json), "Rolled: 4");
    }

    #[test]
    fn extract_roll_display_with_value() {
        let json = r#"{"value":20,"critical":true}"#;
        assert_eq!(extract_roll_display(json), "Rolled: 20");
    }

    #[test]
    fn extract_roll_display_fallback() {
        let json = r#"{"status":"ok"}"#;
        assert_eq!(extract_roll_display(json), "Roll completed.");
    }

    #[test]
    fn extract_roll_display_empty() {
        assert_eq!(extract_roll_display(""), "Roll completed.");
    }
}
