//! TRPG Action Panel — player action submission and dice rolling.
//!
//! Binds DOM event listeners on `#action-panel` elements:
//! - Submit button / Enter key → MCP Tool `masc_trpg_intervention_submit`
//! - Dice Roll button → MCP Tool `masc_trpg_dice_roll` (Manual override)
//!
//! **Philosophy:**
//! We do NOT directly mutate the game state. We submit *Interventions*.
//! The AI Agents (Keepers) living in this society receive these interventions,
//! contemplate them, and decide whether to act upon them.
//! We are whispers in their ears, not puppeteers.

use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use serde_json::json;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use crate::config;
use crate::game::state::{RoomState, TurnProgressState};

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

// ─── Event Bindings ─────────────────────────

#[cfg(target_arch = "wasm32")]
fn bind_submit_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else { return };
    let Some(btn) = doc.get_element_by_id("action-submit-btn") else { return };

    let cb = Closure::wrap(Box::new(move || {
        log::info!("ActionPanel: Submit intervention");
        submit_intervention_from_input();
    }) as Box<dyn FnMut()>);

    let _ = btn.dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn bind_enter_key() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else { return };
    let Some(input) = doc.get_element_by_id("action-input") else { return };

    let cb = Closure::wrap(Box::new(move |event: web_sys::KeyboardEvent| {
        if event.key() == "Enter" {
            submit_intervention_from_input();
        }
    }) as Box<dyn FnMut(web_sys::KeyboardEvent)>);

    let _ = input.dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("keydown", cb.as_ref().unchecked_ref()));
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn bind_dice_roll_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else { return };
    let Some(btn) = doc.get_element_by_id("dice-roll-btn") else { return };

    let cb = Closure::wrap(Box::new(move || {
        log::info!("ActionPanel: Manual Dice Roll (Divine Intervention)");
        set_action_status("Rolling destiny...", "");
        disable_buttons(true);

        wasm_bindgen_futures::spawn_local(async move {
            match roll_dice_intervention().await {
                Ok(text) => set_action_status(&text, "status-ok"),
                Err(e) => {
                    let detail = friendly_js_error(&e);
                    set_action_status(&format!("Roll failed: {}", detail), "status-error");
                }
            }
            // State refresh handled by system
        });
    }) as Box<dyn FnMut()>);

    let _ = btn.dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));
    cb.forget();
}

// ─── Intervention Submission ────────────────

#[cfg(target_arch = "wasm32")]
fn submit_intervention_from_input() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else { return };
    let Some(el) = doc.get_element_by_id("action-input") else { return };
    let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() else { return };

    let text = input.value().trim().to_string();
    if text.is_empty() { return; }
    
    // We send this to the CURRENT ACTOR.
    // "I suggest you do this..."
    let actor_id_opt = get_active_actor_from_dom();
    
    let Some(actor_id) = actor_id_opt else {
        set_action_status("No active agent to whisper to.", "status-error");
        return;
    };

    input.set_value("");
    set_action_status("Whispering to agent...", "");
    disable_buttons(true);

    wasm_bindgen_futures::spawn_local(async move {
        match submit_intervention(&actor_id, &text).await {
            Ok(_) => set_action_status("Whisper sent. Waiting for agent...", "status-ok"),
            Err(e) => {
                let detail = friendly_js_error(&e);
                set_action_status(&format!("Failed to reach agent: {}", detail), "status-error");
            }
        }
    });
}

// ─── JSON-RPC: Submit Intervention ──────────

#[cfg(target_arch = "wasm32")]
async fn submit_intervention(actor_id: &str, suggestion: &str) -> Result<(), JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let url = format!("{}/mcp", config::MASC_MCP_URL); // Using /mcp endpoint
    let room_id = config::current_room_id();

    // Construct MCP Tool Call
    let body = json!({
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": {
            "name": "masc_trpg_intervention_submit",
            "arguments": {
                "session_id": room_id, // tool uses session_id as room_id usually
                "room_id": room_id,
                "target_actor": actor_id,
                "intervention_type": "human_suggestion",
                "reason": "Viewer user input",
                "payload": {
                    "suggestion": suggestion,
                    "priority": "high"
                }
            }
        },
        "id": js_sys::Math::random().to_string()
    }).to_string();

    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_mode(web_sys::RequestMode::Cors);
    opts.set_body(&JsValue::from_str(&body));

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    request.headers().set("Content-Type", "application/json")?;
    // Streamable HTTP headers
    request.headers().set("Accept", "application/json")?; 

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;

    if !resp.ok() {
        let err_body = JsFuture::from(resp.text()?).await?;
        return Err(JsValue::from_str(&format!("RPC Error {}: {:?}", resp.status(), err_body.as_string())));
    }

    // We don't parse the full tool response here, just assume success if HTTP 200.
    // The Agent will see the intervention in their event stream.
    Ok(())
}

// ─── JSON-RPC: Manual Dice Roll ─────────────

#[cfg(target_arch = "wasm32")]
async fn roll_dice_intervention() -> Result<String, JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let Some(actor_id) = get_active_actor_from_dom() else {
        return Err(JsValue::from_str("No active actor"));
    };

    let url = format!("{}/mcp", config::MASC_MCP_URL);
    let room_id = config::current_room_id();

    // Call masc_trpg_dice_roll tool
    let body = json!({
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": {
            "name": "masc_trpg_dice_roll",
            "arguments": {
                "room_id": room_id,
                "actor_id": actor_id,
                "action": "manual_check",
                "stat_value": 0,
                "dc": 0
            }
        },
        "id": js_sys::Math::random().to_string()
    }).to_string();

    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_mode(web_sys::RequestMode::Cors);
    opts.set_body(&JsValue::from_str(&body));

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    request.headers().set("Content-Type", "application/json")?;
    request.headers().set("Accept", "application/json")?;

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;

    if !resp.ok() {
        return Err(JsValue::from_str("Dice roll RPC failed"));
    }

    // Parse result to show something immediately?
    // Usually result is in `result.content[0].text`
    let json_text = JsFuture::from(resp.text()?).await?.as_string().unwrap_or_default();
    Ok(parse_rpc_result(&json_text))
}

#[cfg(target_arch = "wasm32")]
fn parse_rpc_result(json: &str) -> String {
    // Very naive parsing for "total": 15
    if json.contains("total") {
        "Rolled!".to_string() // Simplify, let the event stream update the UI
    } else {
        "Command sent.".to_string()
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
            el.set_inner_html(text);
            el.set_class_name(css_class);
        }
    }
}

#[cfg(target_arch = "wasm32")]
pub(crate) fn friendly_js_error(val: &JsValue) -> String {
    val.as_string()
        .or_else(|| {
            val.dyn_ref::<js_sys::Error>()
                .map(|e| e.message().into())
        })
        .unwrap_or_else(|| format!("{:?}", val))
}

#[cfg(target_arch = "wasm32")]
fn get_active_actor_from_dom() -> Option<String> {
    let doc = web_sys::window().and_then(|w| w.document())?;
    let panel = doc.get_element_by_id("action-panel")?;
    let actor_id = panel.get_attribute("data-active-actor").unwrap_or_default();
    if actor_id.is_empty() { None } else { Some(actor_id) }
}

#[cfg(target_arch = "wasm32")]
fn disable_buttons(disabled: bool) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else { return };
    
    if let Some(btn) = doc.get_element_by_id("action-submit-btn") {
        if disabled { let _ = btn.set_attribute("disabled", "true"); }
        else { let _ = btn.remove_attribute("disabled"); }
    }
    if let Some(btn) = doc.get_element_by_id("dice-roll-btn") {
        if disabled { let _ = btn.set_attribute("disabled", "true"); }
        else { let _ = btn.remove_attribute("disabled"); }
    }
}

// ─── System ─────────────────────────────────

pub fn sync_action_panel_interaction_state(
    _room_state: Res<RoomState>,
    _progress: Res<TurnProgressState>,
) {
    #[cfg(target_arch = "wasm32")]
    {
        let active_actor = &progress.current_actor;
        let can_act = !active_actor.is_empty() && active_actor != "dm"; 

        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(panel) = doc.get_element_by_id("action-panel") {
                let _ = panel.set_attribute("data-active-actor", active_actor);
            }
            
            // Enable buttons if there's an actor (even if not strictly ours - we are Whisperers)
            disable_buttons(!can_act);

            if let Some(input) = doc.get_element_by_id("action-input") {
                let placeholder = if can_act {
                    format!("Whisper suggestion to {}...", active_actor) // Changed text
                } else {
                    "Waiting for agent turn...".to_string()
                };
                let _ = input.set_attribute("placeholder", &placeholder);
            }
        }
    }
}
