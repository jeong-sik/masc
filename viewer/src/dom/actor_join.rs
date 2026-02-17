//! Actor Join/Leave Panel — claim and release TRPG actors via REST.
//!
//! Binds DOM event listeners on `#join-panel` elements:
//! - Join button → POST `/api/v1/trpg/actors/claim`
//! - Leave button → POST `/api/v1/trpg/actors/release`
//!
//! On successful claim, hides the join panel and shows the action panel.
//! On release, reverses the swap.

use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use crate::config;
#[cfg(target_arch = "wasm32")]
use crate::dom::action_panel::friendly_js_error;
use crate::game::state::{RoomState, TurnProgressState};

// ─── Marker Resource ────────────────────────

/// Inserted on enter, removed on exit — signals that the actor join panel is bound.
#[derive(Resource)]
pub struct ActorJoinBound;

// ─── OnEnter System ─────────────────────────

/// Bind DOM event listeners when entering TRPG mode.
pub fn bind_actor_join(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    {
        bind_join_button();
        bind_leave_button();
        restore_join_panel_state(); // Restore UI state from hidden inputs if available
        log::info!("ActorJoin: bound");
    }

    commands.insert_resource(ActorJoinBound);
}

/// Cleanup when leaving TRPG mode.
pub fn unbind_actor_join(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    log::info!("ActorJoin: unbound");

    commands.remove_resource::<ActorJoinBound>();
}

// ─── Interaction State Sync System ──────────

/// Disable join controls when the room is not in an interactive state.
/// This prevents confusing claim errors for ended/idle/unavailable rooms.
pub fn sync_join_panel_interaction_state(
    room_state: Res<RoomState>,
    progress: Res<TurnProgressState>,
) {
    let _ = (&room_state, &progress);

    #[cfg(target_arch = "wasm32")]
    {
        fn normalize_room_status(raw: &str) -> String {
            let normalized = raw.trim().to_ascii_lowercase();
            if normalized.is_empty() {
                "unknown".to_string()
            } else {
                normalized
            }
        }

        fn effective_room_status(room_status: &str, progress_status: &str) -> String {
            if !progress_status.is_empty() {
                normalize_room_status(progress_status)
            } else {
                normalize_room_status(room_status)
            }
        }

        fn room_accepts_join(status: &str) -> bool {
            matches!(
                status,
                "active"
                    | "running"
                    | "in_progress"
                    | "round"
                    | "combat"
                    | "briefing"
                    | "dm_narration"
                    | "party_discussion"
                    | "action_declaration"
                    | "dice_resolution"
                    | "outcome_narration"
                    | "state_update"
                    | "transition"
            )
        }

        fn room_blocked_join_message(status: &str) -> Option<&'static str> {
            match status {
                "ended" => Some("Game Ended"),
                "archived" => Some("Archived"),
                "error" => Some("Error State"),
                _ => None,
            }
        }

        let status = effective_room_status(&room_state.status, &progress.room_status);
        let can_join = room_accepts_join(&status);

        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        if let Some(btn) = doc.get_element_by_id("join-btn") {
            if can_join {
                let _ = btn.remove_attribute("disabled");
                let _ = btn.set_attribute("title", "Claim actor and join game");
            } else {
                let _ = btn.set_attribute("disabled", "true");
                let reason = room_blocked_join_message(&status).unwrap_or("Unavailable");
                let _ = btn.set_attribute("title", reason);
            }
        }
    }
}

// ─── Event: Join Button ─────────────────────

#[cfg(target_arch = "wasm32")]
fn bind_join_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc.get_element_by_id("join-btn") else {
        log::warn!("ActorJoin: #join-btn not found");
        return;
    };

    let cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        // 1. Get input values
        let actor_id_input = doc
            .get_element_by_id("actor-id-input")
            .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok());
        let keeper_input = doc
            .get_element_by_id("keeper-input")
            .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok());

        let actor_id = actor_id_input.map(|i| i.value()).unwrap_or_default();
        let keeper_name = keeper_input.map(|i| i.value()).unwrap_or_default();

        if actor_id.trim().is_empty() {
            set_join_status("Actor ID is required", "status-error");
            return;
        }

        // 2. Disable button while processing
        if let Some(btn) = doc.get_element_by_id("join-btn") {
            let _ = btn.set_attribute("disabled", "true");
        }
        set_join_status("Joining...", "");

        // 3. Spawn async claim request
        let actor_id_clone = actor_id.clone();
        wasm_bindgen_futures::spawn_local(async move {
            match claim_actor(&actor_id, &keeper_name).await {
                Ok(_) => {
                    set_join_status("Joined successfully", "status-ok");
                    swap_to_action_panel(&actor_id_clone);
                }
                Err(e) => {
                    let detail = friendly_js_error(&e);
                    log::warn!("Claim failed: {:?}", detail);
                    set_join_status(&format!("Join failed: {}", detail), "status-error");

                    // Re-enable button on error
                    if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
                        if let Some(btn) = doc.get_element_by_id("join-btn") {
                            let _ = btn.remove_attribute("disabled");
                        }
                    }
                }
            }
        });
    }) as Box<dyn FnMut()>);

    let _ = btn
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));

    cb.forget();
}

// ─── Event: Leave Button ────────────────────

#[cfg(target_arch = "wasm32")]
fn bind_leave_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc.get_element_by_id("leave-btn") else {
        log::warn!("ActorJoin: #leave-btn not found");
        return;
    };

    let cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        // Get claimed actor ID from hidden state (or just the UI text if we had it)
        // Ideally we stored it somewhere. For now, let's grab from the DOM display if possible,
        // or rely on the stored hidden input.
        let claimed_id = get_claimed_actor_id_from_dom().unwrap_or_default();
        if claimed_id.is_empty() {
            set_join_status("No active session to leave", "status-error");
            return;
        }

        // Disable button
        if let Some(btn) = doc.get_element_by_id("leave-btn") {
            let _ = btn.set_attribute("disabled", "true");
        }

        // Spawn async release request
        let actor_id = claimed_id.clone();
        wasm_bindgen_futures::spawn_local(async move {
            match release_actor(&actor_id).await {
                Ok(_) => {
                    swap_to_join_panel();
                    set_join_status("Left game", "status-ok");
                }
                Err(e) => {
                    let detail = friendly_js_error(&e);
                    log::warn!("Release failed: {:?}", detail);
                    // Force leave on UI anyway? Or show error?
                    // Usually better to let them try again.
                    set_join_status(&format!("Leave failed: {}", detail), "status-error");

                    if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
                        if let Some(btn) = doc.get_element_by_id("leave-btn") {
                            let _ = btn.remove_attribute("disabled");
                        }
                    }
                }
            }
        });
    }) as Box<dyn FnMut()>);

    let _ = btn
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));

    cb.forget();
}

// ─── HTTP: Claim Actor ──────────────────────

#[cfg(target_arch = "wasm32")]
async fn claim_actor(actor_id: &str, keeper_name: &str) -> Result<(), JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let url = format!("{}/api/v1/trpg/actors/claim", config::MASC_MCP_URL);
    let room_id = config::current_room_id();

    // If keeper_name is empty, default to "Anonymous Viewer"
    let keeper = if keeper_name.trim().is_empty() {
        "Anonymous Viewer"
    } else {
        keeper_name
    };

    let body = serde_json::json!({
        "room_id": room_id,
        "actor_id": actor_id,
        "keeper_name": keeper
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
        let err_text = err_body.as_string().unwrap_or_default();
        // Parse error json if possible
        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&err_text) {
            if let Some(detail) = json.get("detail").and_then(|v| v.as_str()) {
                return Err(JsValue::from_str(detail));
            }
        }
        return Err(JsValue::from_str(&format!(
            "HTTP {} - {}",
            resp.status(),
            err_text
        )));
    }

    Ok(())
}

// ─── HTTP: Release Actor ────────────────────

#[cfg(target_arch = "wasm32")]
async fn release_actor(actor_id: &str) -> Result<(), JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let url = format!("{}/api/v1/trpg/actors/release", config::MASC_MCP_URL);
    let room_id = config::current_room_id();

    // Retrieve keeper name from hidden state if possible, or send empty (server might require it?)
    // The current API spec for release requires `keeper_name`.
    let keeper = get_claimed_keeper_from_dom().unwrap_or("Anonymous Viewer".to_string());

    let body = serde_json::json!({
        "room_id": room_id,
        "actor_id": actor_id,
        "keeper_name": keeper,
        "reason": "Viewer user left"
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
        let err_text = err_body.as_string().unwrap_or_default();
        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&err_text) {
            if let Some(detail) = json.get("detail").and_then(|v| v.as_str()) {
                return Err(JsValue::from_str(detail));
            }
        }
        return Err(JsValue::from_str(&format!(
            "HTTP {} - {}",
            resp.status(),
            err_text
        )));
    }

    Ok(())
}

// ─── UI Helpers ─────────────────────────────

#[cfg(target_arch = "wasm32")]
fn set_join_status(text: &str, css_class: &str) {
    if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
        if let Some(el) = doc.get_element_by_id("join-status") {
            el.set_inner_html(text);
            el.set_class_name(css_class);
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn swap_to_action_panel(actor_id: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };

    // Hide join panel
    if let Some(el) = doc.get_element_by_id("join-panel") {
        let _ = el.set_attribute("style", "display: none;");
    }

    // Show action panel
    if let Some(el) = doc.get_element_by_id("action-panel") {
        let _ = el.remove_attribute("style"); // removes display:none
    }

    // Update player info display
    if let Some(el) = doc.get_element_by_id("player-actor-id") {
        el.set_inner_html(actor_id);
    }

    // Store state in hidden inputs (for persistence across re-renders if needed)
    set_claimed_state(actor_id);
}

#[cfg(target_arch = "wasm32")]
fn swap_to_join_panel() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };

    // Hide action panel
    if let Some(el) = doc.get_element_by_id("action-panel") {
        let _ = el.set_attribute("style", "display: none;");
    }

    // Show join panel
    if let Some(el) = doc.get_element_by_id("join-panel") {
        let _ = el.remove_attribute("style");
    }

    // Clear player info
    if let Some(el) = doc.get_element_by_id("player-actor-id") {
        el.set_inner_html("");
    }

    // Clear state
    clear_claimed_state();

    // Reset buttons
    if let Some(btn) = doc.get_element_by_id("join-btn") {
        let _ = btn.remove_attribute("disabled");
    }
    if let Some(btn) = doc.get_element_by_id("leave-btn") {
        let _ = btn.remove_attribute("disabled");
    }
}

#[cfg(target_arch = "wasm32")]
fn set_claimed_state(actor_id: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };

    if let Some(el) = doc.get_element_by_id("claimed-actor-id") {
        if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
            input.set_value(actor_id);
        }
    }

    // Also save keeper name?
    if let Some(k_input) = doc.get_element_by_id("keeper-input") {
        if let Some(input) = k_input.dyn_ref::<web_sys::HtmlInputElement>() {
            let keeper = input.value();
            if let Some(hidden) = doc.get_element_by_id("claimed-keeper") {
                if let Some(h_input) = hidden.dyn_ref::<web_sys::HtmlInputElement>() {
                    h_input.set_value(&keeper);
                }
            }
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn clear_claimed_state() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };

    if let Some(el) = doc.get_element_by_id("claimed-actor-id") {
        if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
            input.set_value("");
        }
    }
    if let Some(el) = doc.get_element_by_id("claimed-keeper") {
        if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
            input.set_value("");
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn get_claimed_actor_id_from_dom() -> Option<String> {
    let doc = web_sys::window().and_then(|w| w.document())?;
    let el = doc.get_element_by_id("claimed-actor-id")?;
    let input = el.dyn_ref::<web_sys::HtmlInputElement>()?;
    let val = input.value();
    if val.is_empty() {
        None
    } else {
        Some(val)
    }
}

#[cfg(target_arch = "wasm32")]
fn get_claimed_keeper_from_dom() -> Option<String> {
    let doc = web_sys::window().and_then(|w| w.document())?;
    let el = doc.get_element_by_id("claimed-keeper")?;
    let input = el.dyn_ref::<web_sys::HtmlInputElement>()?;
    let val = input.value();
    if val.is_empty() {
        None
    } else {
        Some(val)
    }
}

#[cfg(target_arch = "wasm32")]
fn restore_join_panel_state() {
    let Some(actor_id) = get_claimed_actor_id_from_dom() else {
        // No claimed actor, ensure join panel is visible
        swap_to_join_panel();
        return;
    };

    // Have claimed actor, show action panel
    swap_to_action_panel(&actor_id);
}
