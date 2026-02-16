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
        refresh_action_panel_interaction_state();
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
    let Some(actor_id) = current_playable_actor_id() else {
        set_action_status(
            "파티 actor가 없어 액션을 제출할 수 없습니다. 새 게임을 시작하세요.",
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

    log::info!("ActionPanel: action submitted");
    Ok(())
}

// ─── HTTP: Dice Roll ────────────────────────

#[cfg(target_arch = "wasm32")]
async fn roll_dice() -> Result<String, JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let url = format!("{}/api/v1/trpg/dice/roll", config::MASC_MCP_URL);
    let room_id = config::current_room_id();
    let actor_id = current_playable_actor_id()
        .ok_or_else(|| JsValue::from_str("no playable actor in current party"))?;

    let body = json!({
        "room_id": room_id,
        "actor_id": actor_id,
        "action": "manual_roll",
        "stat_value": 10,
        "dc": 12
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
#[allow(dead_code)]
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

// ─── Error Formatting ──────────────────────

/// Extract a short, user-readable message from a JsValue error.
/// Network failures (server down) produce `TypeError: Failed to fetch` wrapped
/// in a WASM stack trace — this strips it down to one line.
#[cfg(target_arch = "wasm32")]
pub(crate) fn friendly_js_error(e: &JsValue) -> String {
    // JsValue may be a string or a JS Error object.
    if let Some(s) = e.as_string() {
        return s;
    }
    // Try .message property (JS Error objects)
    if let Ok(msg) = js_sys::Reflect::get(e, &JsValue::from_str("message")) {
        if let Some(s) = msg.as_string() {
            if s.contains("Failed to fetch") {
                return "서버에 연결할 수 없습니다. MASC 서버가 실행 중인지 확인하세요.".to_string();
            }
            // Return just the first line of the message
            return s.lines().next().unwrap_or(&s).to_string();
        }
    }
    // Last resort: Debug format, but truncated
    let debug = format!("{:?}", e);
    if debug.contains("Failed to fetch") {
        return "서버에 연결할 수 없습니다. MASC 서버가 실행 중인지 확인하세요.".to_string();
    }
    debug.chars().take(120).collect()
}

#[cfg(target_arch = "wasm32")]
fn normalize_room_status(raw: &str) -> String {
    let normalized = raw.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        "unknown".to_string()
    } else {
        normalized
    }
}

#[cfg(target_arch = "wasm32")]
fn effective_room_status(room_state: &RoomState, progress: &TurnProgressState) -> String {
    if !progress.room_status.trim().is_empty() {
        normalize_room_status(&progress.room_status)
    } else {
        normalize_room_status(&room_state.status)
    }
}

#[cfg(target_arch = "wasm32")]
fn room_accepts_actions(status: &str) -> bool {
    matches!(status, "active" | "running")
}

#[cfg(target_arch = "wasm32")]
fn blocked_action_placeholder(status: &str) -> &'static str {
    match status {
        "paused" => "게임 일시정지 상태입니다. 재개 후 액션을 제출하세요.",
        "ended" => "게임이 종료되었습니다. 새 게임을 시작하세요.",
        "idle" => "진행 중 게임이 없습니다. 새 게임을 시작하세요.",
        "loading" => "방 상태를 불러오는 중입니다.",
        "unavailable" => "엔진 연결 불가 상태입니다.",
        _ => "현재 방 상태에서는 액션을 제출할 수 없습니다.",
    }
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

#[cfg(target_arch = "wasm32")]
fn current_playable_actor_id() -> Option<String> {
    let doc = web_sys::window().and_then(|w| w.document())?;
    let cards = doc.query_selector_all("#character-panel .character-card").ok()?;
    for i in 0..cards.length() {
        let Some(node) = cards.item(i) else { continue };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };
        let actor_id = el
            .get_attribute("data-actor-id")
            .unwrap_or_default()
            .trim()
            .to_string();
        if actor_id.is_empty() || actor_id == "dm" {
            continue;
        }
        let is_dead = el.class_name().split_whitespace().any(|name| name == "dead");
        if is_dead {
            continue;
        }
        return Some(actor_id);
    }
    None
}

#[cfg(target_arch = "wasm32")]
fn refresh_action_panel_interaction_state() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let has_actor = current_playable_actor_id().is_some();

    if let Some(el) = doc.get_element_by_id("action-input") {
        if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
            input.set_disabled(!has_actor);
            input.set_placeholder(if has_actor {
                "Describe your action..."
            } else {
                "파티 actor 없음 — 새 게임/세션 준비 필요"
            });
        }
    }

    for id in &["action-submit-btn", "dice-roll-btn"] {
        if let Some(el) = doc.get_element_by_id(id) {
            if let Some(btn) = el.dyn_ref::<web_sys::HtmlButtonElement>() {
                btn.set_disabled(!has_actor);
            }
        }
    }
}

// ─── Bevy System: Visibility Sync ───────────

/// Hides the action panel when not in TRPG mode.
/// The panel HTML always exists in index.html but should only be visible in TRPG.
pub fn sync_action_panel_visibility(
    mode: Res<State<ViewerMode>>,
    room_state: Res<RoomState>,
    progress: Res<TurnProgressState>,
) {
    let _ = mode; // read to register as system parameter
    let _ = (&room_state, &progress);

    #[cfg(target_arch = "wasm32")]
    {
        let trpg_visible = matches!(mode.get(), ViewerMode::Trpg);
        let status = effective_room_status(&room_state, &progress);
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let claimed_actor = doc
            .get_element_by_id("claimed-actor-id")
            .and_then(|el| el.dyn_ref::<web_sys::HtmlInputElement>().map(|i| i.value()))
            .unwrap_or_default();
        let has_claim = !claimed_actor.trim().is_empty();
        let panel_visible = trpg_visible && has_claim;

        if let Some(el) = doc.get_element_by_id("action-panel") {
            if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
                let _ = html_el
                    .style()
                    .set_property("display", if panel_visible { "block" } else { "none" });
            }
        }
        if panel_visible {
            refresh_action_panel_interaction_state();

            let has_actor = current_playable_actor_id().is_some();
            let can_act = has_actor && room_accepts_actions(&status);

            if let Some(el) = doc.get_element_by_id("action-input") {
                if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
                    input.set_disabled(!can_act);
                    if !room_accepts_actions(&status) {
                        input.set_placeholder(blocked_action_placeholder(&status));
                    }
                }
            }

            for id in &["action-submit-btn", "dice-roll-btn"] {
                if let Some(el) = doc.get_element_by_id(id) {
                    if let Some(btn) = el.dyn_ref::<web_sys::HtmlButtonElement>() {
                        btn.set_disabled(!can_act);
                    }
                }
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
