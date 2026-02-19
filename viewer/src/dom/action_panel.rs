//! TRPG Action Panel — player action submission and dice rolling.
//!
//! Binds DOM event listeners on `#action-panel` elements:
//! - Submit button / Enter key → MCP Tool `masc_trpg_intervention_submit`
//! - Dice Roll button → MCP Tool `masc_trpg_dice_roll` (Manual override)
//! - Escape key → clear input and blur
//!
//! **Philosophy:**
//! We do NOT directly mutate the game state. We submit *Interventions*.
//! The AI Agents (Keepers) living in this society receive these interventions,
//! contemplate them, and decide whether to act upon them.
//! We are whispers in their ears, not puppeteers.
//!
//! **Closure lifecycle:** Event listeners use `Closure::forget()` intentionally.
//! WASM closures passed to JS must live as long as the DOM element. Since the
//! action panel DOM elements are removed on `OnExit(ViewerMode::Trpg)`, the JS
//! garbage collector reclaims the closure references when the elements are destroyed.
//! The `data-bound` attribute prevents double-binding on re-entry.

use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use serde_json::json;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use crate::config;
#[cfg(target_arch = "wasm32")]
use crate::game::lifecycle::TrpgLifecycleState;
use crate::game::state::{ConnectionStatus, RoomState, TurnProgressState};
#[cfg(target_arch = "wasm32")]
use crate::http::{self, RpcResult};

// ─── Constants ──────────────────────────────

/// Maximum length for action input text.
const MAX_ACTION_LEN: usize = 500;

/// Maximum number of entries in the action history panel.
const MAX_HISTORY_ENTRIES: u32 = 5;

/// Milliseconds before auto-clearing a success status message.
#[cfg(target_arch = "wasm32")]
const STATUS_CLEAR_DELAY_MS: i32 = 3000;

// ─── Pure validation (testable without DOM) ─

/// Validate action input text. Returns `Ok(())` or an error message.
#[cfg(any(target_arch = "wasm32", test))]
pub(crate) fn validate_action_input(text: &str) -> Result<(), &'static str> {
    if text.is_empty() {
        return Err("Enter an action first");
    }
    if text.len() > MAX_ACTION_LEN {
        return Err("Action too long (max 500 chars)");
    }
    Ok(())
}

/// Extract a user-friendly display string from a successful dice roll RPC result.
#[cfg(any(target_arch = "wasm32", test))]
pub(crate) fn format_dice_result(rpc_result_json: &str) -> String {
    // Try to extract total from the MCP tool result content
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(rpc_result_json) {
        // MCP tool results are usually in result.content[0].text
        if let Some(content) = val.get("content").and_then(|c| c.as_array()) {
            if let Some(text) = content
                .first()
                .and_then(|c| c.get("text"))
                .and_then(|t| t.as_str())
            {
                // Try to parse the text as JSON for structured dice results
                if let Ok(inner) = serde_json::from_str::<serde_json::Value>(text) {
                    if let Some(total) = inner.get("total").and_then(|t| t.as_i64()) {
                        return format!("Rolled: {}", total);
                    }
                }
                // Fallback: use the text as-is if short enough
                if text.len() <= 80 {
                    return text.to_string();
                }
            }
        }
        // Direct result with total field
        if let Some(total) = val.get("total").and_then(|t| t.as_i64()) {
            return format!("Rolled: {}", total);
        }
    }
    "Rolled.".to_string()
}

/// Check if connection status allows player input.
#[cfg(any(target_arch = "wasm32", test))]
fn connection_ready(status: &ConnectionStatus) -> bool {
    matches!(status, ConnectionStatus::Connected)
}

// ─── Marker Resource ────────────────────────

#[derive(Resource)]
pub struct ActionPanelBound;

// ─── OnEnter System ─────────────────────────

pub fn bind_action_panel(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    {
        log::info!("ActionPanel: Binding listeners (Intervention Mode)...");
        bind_submit_button();
        bind_enter_key();
        bind_escape_key();
        bind_dice_roll_button();
        clear_action_status();

        log::info!("ActionPanel: bound complete");
    }

    commands.insert_resource(ActionPanelBound);
}

pub fn unbind_action_panel(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    {
        clear_action_status();
        clear_action_input();
        log::info!("ActionPanel: unbound");
    }

    commands.remove_resource::<ActionPanelBound>();
}

// ─── Flight Lock ────────────────────────────
//
// Prevents concurrent async operations using a DOM attribute as a mutex.
// Adopted from turn_controls.rs `data-round-flight-owner` pattern.

#[cfg(target_arch = "wasm32")]
fn try_acquire_flight(doc: &web_sys::Document, owner: &str) -> bool {
    let Some(panel) = doc.get_element_by_id("action-panel") else {
        return false;
    };
    if panel.get_attribute("data-action-flight").is_some() {
        return false;
    }
    let _ = panel.set_attribute("data-action-flight", owner);
    true
}

#[cfg(target_arch = "wasm32")]
fn release_flight(doc: &web_sys::Document) {
    if let Some(panel) = doc.get_element_by_id("action-panel") {
        let _ = panel.remove_attribute("data-action-flight");
    }
}

// ─── Event Bindings ─────────────────────────

#[cfg(target_arch = "wasm32")]
fn bind_submit_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc.get_element_by_id("action-submit-btn") else {
        return;
    };
    if btn.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = btn.set_attribute("data-bound", "1");

    let cb = Closure::wrap(Box::new(move || {
        log::info!("ActionPanel: Submit intervention");
        submit_intervention_from_input();
    }) as Box<dyn FnMut()>);

    let _ = btn
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn bind_enter_key() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(input) = doc.get_element_by_id("action-input") else {
        return;
    };
    if input.get_attribute("data-enter-bound").as_deref() == Some("1") {
        return;
    }
    let _ = input.set_attribute("data-enter-bound", "1");

    let cb = Closure::wrap(Box::new(move |event: web_sys::KeyboardEvent| {
        if event.key() == "Enter" {
            submit_intervention_from_input();
        }
    }) as Box<dyn FnMut(web_sys::KeyboardEvent)>);

    let _ = input
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("keydown", cb.as_ref().unchecked_ref()));
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn bind_escape_key() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(input) = doc.get_element_by_id("action-input") else {
        return;
    };
    if input.get_attribute("data-escape-bound").as_deref() == Some("1") {
        return;
    }
    let _ = input.set_attribute("data-escape-bound", "1");

    let cb = Closure::wrap(Box::new(move |event: web_sys::KeyboardEvent| {
        if event.key() == "Escape" {
            if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
                if let Some(el) = doc.get_element_by_id("action-input") {
                    if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
                        input.set_value("");
                        let _ = input.blur();
                    }
                }
            }
        }
    }) as Box<dyn FnMut(web_sys::KeyboardEvent)>);

    let _ = input
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("keydown", cb.as_ref().unchecked_ref()));
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn bind_dice_roll_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc.get_element_by_id("dice-roll-btn") else {
        return;
    };
    if btn.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = btn.set_attribute("data-bound", "1");

    let cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        if !try_acquire_flight(&doc, "dice") {
            set_action_status("Action in progress...", "status-pending");
            return;
        }

        log::info!("ActionPanel: Manual Dice Roll (Divine Intervention)");
        set_action_status("Rolling destiny...", "status-pending");
        disable_buttons(true);

        wasm_bindgen_futures::spawn_local(async move {
            let result = roll_dice_intervention().await;

            // Always re-enable buttons and release flight lock
            disable_buttons(false);
            if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
                release_flight(&doc);
            }

            match result {
                Ok(text) => {
                    set_action_status(&text, "status-ok");
                    schedule_status_clear();
                }
                Err(msg) => {
                    set_action_status(&format!("Roll failed: {}", msg), "status-error");
                }
            }
        });
    }) as Box<dyn FnMut()>);

    let _ = btn
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));
    cb.forget();
}

// ─── Intervention Submission ────────────────

#[cfg(target_arch = "wasm32")]
fn submit_intervention_from_input() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(el) = doc.get_element_by_id("action-input") else {
        return;
    };
    let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() else {
        return;
    };

    let text = input.value().trim().to_string();

    // P1: Input validation
    if let Err(msg) = validate_action_input(&text) {
        set_action_status(msg, "status-error");
        return;
    }

    let actor_id_opt = get_active_actor_from_dom();
    let Some(actor_id) = actor_id_opt else {
        set_action_status("No active agent to whisper to.", "status-error");
        return;
    };

    // P1: Flight lock — prevent concurrent submits
    if !try_acquire_flight(&doc, "submit") {
        set_action_status("Action in progress...", "status-pending");
        return;
    }

    input.set_value("");
    set_action_status("Whispering to agent...", "status-pending");
    disable_buttons(true);

    let text_for_history = text.clone();

    wasm_bindgen_futures::spawn_local(async move {
        let result = submit_intervention(&actor_id, &text).await;

        // Always re-enable buttons and release flight lock (P0 fix)
        disable_buttons(false);
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            release_flight(&doc);
        }

        match result {
            Ok(()) => {
                set_action_status("Whisper sent. Waiting for agent...", "status-ok");
                append_to_history(&text_for_history);
                schedule_status_clear();
            }
            Err(msg) => {
                set_action_status(&format!("Failed to reach agent: {}", msg), "status-error");
            }
        }
    });
}

// ─── JSON-RPC: Submit Intervention ──────────

#[cfg(target_arch = "wasm32")]
async fn submit_intervention(actor_id: &str, suggestion: &str) -> Result<(), String> {
    let url = format!("{}/mcp", config::MASC_MCP_URL);
    let room_id = config::current_room_id();

    let params = json!({
        "name": "masc_trpg_intervention_submit",
        "arguments": {
            "session_id": room_id,
            "room_id": room_id,
            "target_actor": actor_id,
            "intervention_type": "human_suggestion",
            "reason": "Viewer user input",
            "payload": {
                "suggestion": suggestion,
                "priority": "high"
            }
        }
    });

    match http::rpc_call(&url, "tools/call", params).await {
        RpcResult::Ok(_) => Ok(()),
        other => Err(other.display_error()),
    }
}

// ─── JSON-RPC: Manual Dice Roll ─────────────

#[cfg(target_arch = "wasm32")]
async fn roll_dice_intervention() -> Result<String, String> {
    let Some(actor_id) = get_active_actor_from_dom() else {
        return Err("No active actor".into());
    };

    let url = format!("{}/mcp", config::MASC_MCP_URL);
    let room_id = config::current_room_id();

    let params = json!({
        "name": "masc_trpg_dice_roll",
        "arguments": {
            "room_id": room_id,
            "actor_id": actor_id,
            "action": "manual_check",
            "stat_value": 0,
            "dc": 0
        }
    });

    match http::rpc_call(&url, "tools/call", params).await {
        RpcResult::Ok(result_json) => Ok(format_dice_result(&result_json)),
        other => Err(other.display_error()),
    }
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
            el.set_text_content(Some(text));
            el.set_class_name(css_class);
        }
    }
}

/// Schedule auto-clear of the status message after a delay.
#[cfg(target_arch = "wasm32")]
fn schedule_status_clear() {
    let cb = Closure::once(Box::new(move || {
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(el) = doc.get_element_by_id("action-status") {
                // Only clear if the current message is a success message
                if el.class_name() == "status-ok" {
                    el.set_text_content(Some("Ready"));
                    el.set_class_name("");
                }
            }
        }
    }) as Box<dyn FnOnce()>);

    if let Some(window) = web_sys::window() {
        let _ = window.set_timeout_with_callback_and_timeout_and_arguments_0(
            cb.as_ref().unchecked_ref(),
            STATUS_CLEAR_DELAY_MS,
        );
    }
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
pub(crate) fn friendly_js_error(val: &JsValue) -> String {
    val.as_string()
        .or_else(|| val.dyn_ref::<js_sys::Error>().map(|e| e.message().into()))
        .unwrap_or_else(|| format!("{:?}", val))
}

#[cfg(target_arch = "wasm32")]
fn get_active_actor_from_dom() -> Option<String> {
    let doc = web_sys::window().and_then(|w| w.document())?;
    let panel = doc.get_element_by_id("action-panel")?;
    let actor_id = panel.get_attribute("data-active-actor").unwrap_or_default();
    if actor_id.is_empty() {
        None
    } else {
        Some(actor_id)
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

// ─── Action History ─────────────────────────

/// Append a completed action to the action history panel (max 5 entries).
#[cfg(target_arch = "wasm32")]
fn append_to_history(text: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(history) = doc.get_element_by_id("action-history") else {
        return;
    };

    let Ok(entry) = doc.create_element("div") else {
        return;
    };
    entry.set_class_name("history-entry");

    // Truncate display text for readability
    let display = if text.len() > 60 {
        format!("{}...", &text[..60])
    } else {
        text.to_string()
    };
    entry.set_text_content(Some(&display));

    // Prepend (newest first)
    let _ = history.prepend_with_node_1(&entry);

    // Trim to max entries
    while history.child_element_count() > MAX_HISTORY_ENTRIES {
        if let Some(last) = history.last_element_child() {
            last.remove();
        } else {
            break;
        }
    }
}

// ─── System ─────────────────────────────────

#[allow(unused_variables)]
pub fn sync_action_panel_interaction_state(
    room_state: Res<RoomState>,
    progress: Res<TurnProgressState>,
    connection: Res<ConnectionStatus>,
) {
    let _ = &room_state;
    let _ = &connection;
    #[cfg(target_arch = "wasm32")]
    {
        let active_actor = &progress.current_actor;
        let lifecycle =
            TrpgLifecycleState::from_room_progress(&room_state.status, &progress.room_status);
        let connected = connection_ready(&connection);

        // P2: Connection-aware disable — all three conditions must be true
        let can_act = lifecycle.accepts_player_input()
            && !active_actor.is_empty()
            && active_actor != "dm"
            && connected;

        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(panel) = doc.get_element_by_id("action-panel") {
                let _ = panel.set_attribute("data-active-actor", active_actor);
            }

            // Only disable from system sync if no flight is in progress
            // (flight lock handles its own button state)
            let flight_active = doc
                .get_element_by_id("action-panel")
                .and_then(|p| p.get_attribute("data-action-flight"))
                .is_some();

            if !flight_active {
                disable_buttons(!can_act);
            }

            if let Some(input) = doc.get_element_by_id("action-input") {
                let placeholder = if !connected {
                    "Connecting to engine...".to_string()
                } else if can_act {
                    format!("Whisper suggestion to {}...", active_actor)
                } else if !lifecycle.accepts_player_input() {
                    format!("{}...", lifecycle.help_text())
                } else {
                    "Waiting for agent turn...".to_string()
                };
                let _ = input.set_attribute("placeholder", &placeholder);
            }
        }
    }
}

// ─── Tests ──────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_empty_input() {
        assert_eq!(validate_action_input(""), Err("Enter an action first"));
    }

    #[test]
    fn validate_normal_input() {
        assert!(validate_action_input("I attack the goblin").is_ok());
    }

    #[test]
    fn validate_max_length_input() {
        let text = "a".repeat(MAX_ACTION_LEN);
        assert!(validate_action_input(&text).is_ok());
    }

    #[test]
    fn validate_too_long_input() {
        let text = "a".repeat(MAX_ACTION_LEN + 1);
        assert_eq!(
            validate_action_input(&text),
            Err("Action too long (max 500 chars)")
        );
    }

    #[test]
    fn format_dice_with_total() {
        let json = r#"{"total":15,"roll":12,"modifier":3}"#;
        assert_eq!(format_dice_result(json), "Rolled: 15");
    }

    #[test]
    fn format_dice_with_mcp_content() {
        let json = r#"{"content":[{"type":"text","text":"{\"total\":18,\"roll\":15}"}]}"#;
        assert_eq!(format_dice_result(json), "Rolled: 18");
    }

    #[test]
    fn format_dice_with_plain_text_content() {
        let json = r#"{"content":[{"type":"text","text":"Natural 20!"}]}"#;
        assert_eq!(format_dice_result(json), "Natural 20!");
    }

    #[test]
    fn format_dice_fallback() {
        assert_eq!(format_dice_result("not json"), "Rolled.");
        assert_eq!(format_dice_result(r#"{"foo":"bar"}"#), "Rolled.");
    }

    #[test]
    fn connection_ready_variants() {
        assert!(connection_ready(&ConnectionStatus::Connected));
        assert!(!connection_ready(&ConnectionStatus::Disconnected));
        assert!(!connection_ready(&ConnectionStatus::Connecting));
        assert!(!connection_ready(&ConnectionStatus::Failed));
    }
}
