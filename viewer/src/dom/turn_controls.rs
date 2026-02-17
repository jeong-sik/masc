//! Turn Controls — advance turn and session management buttons.
//!
//! Binds DOM event listeners on `#turn-controls`:
//! - Advance Turn button → POST `/api/v1/trpg/turns/advance`
//!
//! Visible when the room is in an active TRPG phase.

use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use serde_json::json;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use crate::config;
use crate::game::state::{RoomState, TurnProgressState};

// ─── Marker Resource ────────────────────────

/// Inserted on enter, removed on exit — signals that the turn controls are bound.
#[derive(Resource)]
pub struct TurnControlsBound;

// ─── OnEnter System ─────────────────────────

pub fn bind_turn_controls(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    {
        bind_advance_button();
        clear_turn_status();
        log::info!("TurnControls: bound");
    }

    commands.insert_resource(TurnControlsBound);
}

pub fn unbind_turn_controls(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    {
        clear_turn_status();
        log::info!("TurnControls: unbound");
    }

    commands.remove_resource::<TurnControlsBound>();
}

// ─── Visibility Sync ────────────────────────

/// Show turn controls only when a keeper is claimed (Keeper/GM privilege).
pub fn sync_turn_controls_visibility(
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

        let status = if !progress.room_status.trim().is_empty() {
            normalize_room_status(&progress.room_status)
        } else {
            normalize_room_status(&room_state.status)
        };
        let room_allows_control = is_room_active_for_controls(&status);

        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let Some(panel) = doc.get_element_by_id("turn-controls") else {
            return;
        };
        let has_keeper = doc
            .get_element_by_id("claimed-keeper")
            .and_then(|el| el.dyn_ref::<web_sys::HtmlInputElement>().map(|i| i.value()))
            .map_or(false, |v| !v.trim().is_empty());

        let style = if room_allows_control || has_keeper {
            ""
        } else {
            "display:none"
        };
        let _ = panel.set_attribute("style", style);
    }
}

#[cfg(target_arch = "wasm32")]
fn is_room_active_for_controls(status: &str) -> bool {
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
            | "paused"
    )
}

// ─── Event: Advance Button ──────────────────

#[cfg(target_arch = "wasm32")]
fn bind_advance_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc.get_element_by_id("advance-turn-btn") else {
        return;
    };

    let cb = Closure::wrap(Box::new(move || {
        on_advance_click();
    }) as Box<dyn Fn()>);

    let _ = btn.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref());
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn on_advance_click() {
    set_turn_status("Advancing...", "");
    set_advance_disabled(true);

    wasm_bindgen_futures::spawn_local(async move {
        match advance_turn().await {
            Ok(msg) => set_turn_status(&msg, "status-ok"),
            Err(e) => {
                let detail = e
                    .as_string()
                    .unwrap_or_else(|| format!("{:?}", e));
                log::warn!("Advance turn failed: {}", detail);
                set_turn_status(&format!("Failed: {}", detail), "status-error");
            }
        }
        set_advance_disabled(false);
    });
}

// ─── HTTP: Advance Turn ─────────────────────

#[cfg(target_arch = "wasm32")]
async fn advance_turn() -> Result<String, JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let url = format!("{}/api/v1/trpg/turns/advance", config::MASC_MCP_URL);
    let room_id = config::current_room_id();

    let body = json!({
        "room_id": room_id
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
        let err_body = JsFuture::from(resp.text()?)
            .await
            .ok()
            .and_then(|v| v.as_string())
            .unwrap_or_default();
        let err_body = err_body.trim();
        if err_body.is_empty() {
            return Err(JsValue::from_str(&format!("HTTP {}", resp.status())));
        }
        return Err(JsValue::from_str(&format!(
            "HTTP {}: {}",
            resp.status(),
            err_body
        )));
    }

    // Extract the new turn number from the response JSON
    let resp_text = JsFuture::from(resp.text()?)
        .await
        .ok()
        .and_then(|v| v.as_string())
        .unwrap_or_default();
    log::info!("TurnControls: turn advanced — {}", resp_text);

    Ok("Turn advanced.".to_string())
}

// ─── DOM Helpers ─────────────────────────────

#[cfg(target_arch = "wasm32")]
fn set_turn_status(text: &str, css_class: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    if let Some(el) = doc.get_element_by_id("turn-control-status") {
        el.set_text_content(Some(text));
        let _ = el.set_attribute("class", css_class);
    }
}

#[cfg(target_arch = "wasm32")]
fn clear_turn_status() {
    set_turn_status("", "");
}

#[cfg(target_arch = "wasm32")]
fn set_advance_disabled(disabled: bool) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    if let Some(el) = doc.get_element_by_id("advance-turn-btn") {
        if let Some(btn) = el.dyn_ref::<web_sys::HtmlButtonElement>() {
            btn.set_disabled(disabled);
        }
    }
}
