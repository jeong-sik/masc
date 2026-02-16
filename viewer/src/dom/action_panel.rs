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
use serde_json::json;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use crate::config;
use crate::game::state::{RoomState, TurnProgressState};

// ─── Marker Resource ────────────────────────

/// Inserted on enter, removed on exit — signals that the action panel is bound.
#[derive(Resource)]
pub struct ActionPanelBound;

// ─── OnEnter System ─────────────────────────

/// Bind DOM event listeners when entering TRPG mode.
pub fn bind_action_panel(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    {
        log::info!("ActionPanel: Binding listeners...");
        bind_submit_button();
        bind_enter_key();
        bind_dice_roll_button();
        clear_action_status();
        refresh_action_panel_interaction_state();
        log::info!("ActionPanel: bound complete");
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
        log::info!("ActionPanel: Submit clicked");
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
            log::info!("ActionPanel: Enter key pressed");
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
        log::info!("ActionPanel: Dice Roll clicked");
        set_action_status("Rolling dice...", "");
        disable_buttons(true);

        wasm_bindgen_futures::spawn_local(async move {
            match roll_dice().await {
                Ok(text) => set_action_status(&text, "status-ok"),
                Err(e) => {
                    let detail = friendly_js_error(&e);
                    log::warn!("Dice roll failed: {:?}", e);
                    set_action_status(&format!("Dice roll failed: {}", detail), "status-error");
                }
            }
            refresh_action_panel_interaction_state();
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
    
    let actor_id_opt = current_playable_actor_id();
    log::info!("ActionPanel: submitting for actor={:?}", actor_id_opt);

    let Some(actor_id) = actor_id_opt else {
        set_action_status(
            "파티 actor가 없어 액션을 제출할 수 없습니다. Join Panel에서 Claim하세요.",
            "status-error",
        );
        refresh_action_panel_interaction_state();
        return;
    };

    // Clear input immediately (optimistic UX)
    input.set_value("");
    set_action_status("Submitting...", "");
    disable_buttons(true);

    wasm_bindgen_futures::spawn_local(async move {
        match submit_action(&actor_id, &text).await {
            Ok(()) => set_action_status("Action submitted.", "status-ok"),
            Err(e) => {
                let detail = friendly_js_error(&e);
                log::warn!("Submit failed: {:?}", e);
                set_action_status(&format!("Submit failed: {}", detail), "status-error");
            }
        }
        refresh_action_panel_interaction_state();
    });
}

// ─── HTTP: Submit Action ────────────────────

#[cfg(target_arch = "wasm32")]
async fn submit_action(actor_id: &str, action_text: &str) -> Result<(), JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let url = format!("{}/api/v1/trpg/events", config::MASC_MCP_URL);
    let room_id = config::current_room_id();

    let body = json!({
        "room_id": room_id,
        "event_type": "turn.action.proposed",
        "actor_id": actor_id,
        "payload": {
            "actor_id": actor_id,
            "proposed_action": action_text
        }
    })
    .to_string();

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
        let err_body = JsFuture::from(resp.text()?).await?;
        return Err(JsValue::from_str(&format!(
            "HTTP {} - {:?}",
            resp.status(),
            err_body.as_string().unwrap_or_default()
        )));
    }

    Ok(())
}

// ─── HTTP: Roll Dice ────────────────────────

#[cfg(target_arch = "wasm32")]
async fn roll_dice() -> Result<String, JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let Some(actor_id) = current_playable_actor_id() else {
        return Err(JsValue::from_str("No actor claimed"));
    };

    let url = format!("{}/api/v1/trpg/dice/roll", config::MASC_MCP_URL);
    let room_id = config::current_room_id();

    // Default dice roll (1d20 check)
    // In future, UI could specify stat/skill
    let body = json!({
        "room_id": room_id,
        "actor_id": actor_id,
        "action": "check",
        "stat_value": 0, // raw d20
        "dc": 0,
        "raw_d20": 0 // 0 means server rolls
    })
    .to_string();

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
        let err_body = JsFuture::from(resp.text()?).await?;
        return Err(JsValue::from_str(&format!(
            "HTTP {} - {:?}",
            resp.status(),
            err_body.as_string().unwrap_or_default()
        )));
    }

    let json_text = JsFuture::from(resp.text()?).await?.as_string().unwrap_or_default();
    Ok(extract_roll_display(&json_text))
}

#[allow(dead_code)]
fn extract_roll_display(json_text: &str) -> String {
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(json_text) {
        if let Some(total) = val.get("total").and_then(|v| v.as_i64()) {
            // Also check result (Success/Failure)
            let result = val.get("result").and_then(|v| v.as_str()).unwrap_or("");
            if !result.is_empty() {
                return format!("Rolled {}: {}", total, result);
            }
            return format!("Rolled {}", total);
        }
    }
    "Roll completed.".to_string()
}

// ─── UI Helpers ─────────────────────────────

#[cfg(target_arch = "wasm32")]
fn clear_action_status() {
    set_action_status("Ready", "");
}

#[cfg(target_arch = "wasm32")]
fn clear_action_input() {
    if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
        if let Some(el) = doc.get_element_by_id("action-input") {
            if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
                input.set_value("");
            }
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn set_action_status(text: &str, css_class: &str) {
    if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
        if let Some(el) = doc.get_element_by_id("action-status") {
            el.set_inner_html(text);
            el.set_class_name(css_class);
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn friendly_js_error(val: &JsValue) -> String {
    val.as_string()
        .or_else(|| {
            val.dyn_ref::<js_sys::Error>()
                .map(|e| e.message().into())
        })
        .unwrap_or_else(|| format!("{:?}", val))
}

/// Sync action panel visibility: only show in TRPG mode.
/// Actually, this might overlap with mode-based CSS?
/// Yes, `mode-trpg` class on body handles general visibility.
/// But here we can do fine-grained control if needed.
pub fn sync_action_panel_visibility(
    _room_state: Res<RoomState>,
    _progress: Res<TurnProgressState>,
) {
    // Only update if mode matches?
    // This system runs `in_state(ViewerMode::Trpg)`.
    
    // Check if we have an actor to play
    #[cfg(target_arch = "wasm32")]
    refresh_action_panel_interaction_state();
}

#[cfg(target_arch = "wasm32")]
pub fn refresh_action_panel_interaction_state() {
    let can_act = current_playable_actor_id().is_some();
    // Also check if it's our turn?
    // For now, allow submitting actions anytime (they go to queue).
    // But maybe disable if turn is strictly blocked?
    
    disable_buttons(!can_act);
    
    if !can_act {
        // Optional: show hint?
        // set_action_status("Claim an actor to play", "status-warn");
    }
}

#[cfg(target_arch = "wasm32")]
fn disable_buttons(disabled: bool) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    
    if let Some(btn) = doc.get_element_by_id("action-submit-btn") {
        if disabled {
            let _ = btn.set_attribute("disabled", "true");
        } else {
            let _ = btn.remove_attribute("disabled");
        }
    }
    
    if let Some(btn) = doc.get_element_by_id("dice-roll-btn") {
        if disabled {
            let _ = btn.set_attribute("disabled", "true");
        } else {
            let _ = btn.remove_attribute("disabled");
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn current_playable_actor_id() -> Option<String> {
    // Use config (localStorage) instead of DOM scraping
    config::current_actor_id()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_roll() {
        assert_eq!(extract_roll_display(r#"{"total": 15, "result": "Success"}"#), "Rolled 15: Success");
        assert_eq!(extract_roll_display(r#"{"total": 5}"#), "Rolled 5");
        assert_eq!(extract_roll_display(""), "Roll completed.");
    }
}
