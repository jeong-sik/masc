//! Turn Controls — execute one TRPG round and show round-run status.
//!
//! Binds DOM event listeners on `#turn-controls`:
//! - Run Round button → POST `/api/v1/trpg/rounds/run`
//!
//! Visible when a round run assignment is present:
//! - claimed keeper/actor for local manual play, or
//! - hidden round-run plan fields for AI auto-run flow.
//! Follows the same OnEnter/OnExit lifecycle as `action_panel.rs`.

use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use serde_json::{json, Value};

#[cfg(target_arch = "wasm32")]
use web_sys::{HtmlButtonElement, HtmlInputElement};

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

/// Show turn controls only when a round-run capable assignment exists.
pub fn sync_turn_controls_visibility(room_state: Res<RoomState>, progress: Res<TurnProgressState>) {
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
        let room_allows_control = matches!(status.as_str(), "active" | "running" | "idle");

        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let Some(panel) = doc.get_element_by_id("turn-controls") else {
            return;
        };

        let claimed_keeper = doc
            .get_element_by_id("claimed-keeper")
            .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
            .map(|i| i.value());
        let claimed_actor = doc
            .get_element_by_id("claimed-actor-id")
            .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
            .map(|i| i.value());
        let has_manual_claim = claimed_keeper
            .as_ref()
            .map(|v| !v.trim().is_empty())
            .unwrap_or(false)
            || claimed_actor
                .as_ref()
                .map(|v| !v.trim().is_empty())
                .unwrap_or(false);

        let has_auto_plan = doc
            .get_element_by_id("round-run-dm")
            .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
            .is_some_and(|input| !input.value().trim().is_empty());

        let style = if (has_manual_claim || has_auto_plan) && room_allows_control {
            ""
        } else {
            "display:none"
        };
        let _ = panel.set_attribute("style", style);
    }
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
    set_turn_status("Running round...", "");
    set_advance_disabled(true);

    wasm_bindgen_futures::spawn_local(async move {
        match advance_turn().await {
            Ok(msg) => set_turn_status(&msg, "status-ok"),
            Err(e) => {
                let detail = e.as_string().unwrap_or_else(|| format!("{:?}", e));
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

    let doc = web_sys::window()
        .and_then(|w| w.document())
        .ok_or_else(|| JsValue::from_str("No document"))?;
    let plan = read_round_run_plan(&doc).map_err(|err| JsValue::from_str(&err))?;

    let mut player_keepers = serde_json::Map::new();
    for (actor_id, keeper_name) in &plan.player_keepers {
        player_keepers.insert(actor_id.clone(), Value::String(keeper_name.clone()));
    }

    let url = format!("{}/api/v1/trpg/rounds/run", config::MASC_MCP_URL);
    let body = json!({
        "room_id": config::current_room_id(),
        "dm_keeper": plan.dm_keeper,
        "player_keepers": Value::Object(player_keepers),
        "phase": plan.phase,
        "timeout_sec": plan.timeout_sec,
        "lang": plan.lang
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

    let resp_text = JsFuture::from(resp.text()?)
        .await
        .ok()
        .and_then(|v| v.as_string())
        .unwrap_or_default();
    log::info!("TurnControls: round run response — {}", resp_text);

    if let Ok(json) = serde_json::from_str::<Value>(&resp_text) {
        let turn_before = json.get("turn_before").and_then(Value::as_u64).unwrap_or(0);
        let turn_after = json.get("turn_after").and_then(Value::as_u64).unwrap_or(0);
        if turn_after > 0 {
            return Ok(format!(
                "Round progressed: turn {} → {}",
                turn_before, turn_after
            ));
        }
    }

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
        if let Some(btn) = el.dyn_into::<HtmlButtonElement>().ok() {
            btn.set_disabled(disabled);
        }
    }
}

#[cfg(target_arch = "wasm32")]
struct RoundRunPlan {
    dm_keeper: String,
    phase: String,
    timeout_sec: f64,
    lang: String,
    player_keepers: Vec<(String, String)>,
}

#[cfg(target_arch = "wasm32")]
fn read_round_run_plan(doc: &web_sys::Document) -> Result<RoundRunPlan, String> {
    let dm_keeper = doc
        .get_element_by_id("round-run-dm")
        .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        .map(|i| i.value())
        .unwrap_or_default()
        .trim()
        .to_string();
    if dm_keeper.is_empty() {
        return Err("DM keeper가 설정되지 않았습니다. 새 게임을 먼저 시작하세요.".to_string());
    }

    let phase = doc
        .get_element_by_id("round-run-phase")
        .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        .map(|i| i.value())
        .unwrap_or_else(|| "round".to_string())
        .trim()
        .to_string();
    let lang = doc
        .get_element_by_id("round-run-lang")
        .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        .map(|i| i.value())
        .unwrap_or_else(|| "ko".to_string())
        .trim()
        .to_string();
    let timeout_sec = doc
        .get_element_by_id("round-run-timeout")
        .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        .map(|i| i.value())
        .unwrap_or_else(|| "90".to_string())
        .trim()
        .parse::<f64>()
        .unwrap_or(90.0);

    let player_pairs_raw = doc
        .get_element_by_id("round-run-players")
        .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        .map(|i| i.value())
        .unwrap_or_default();
    let player_keepers = player_pairs_raw
        .split(',')
        .filter_map(|part| {
            let pair = part.trim();
            if pair.is_empty() {
                return None;
            }
            let mut pieces = pair.splitn(2, '=');
            let actor_id = pieces.next()?.trim();
            let keeper = pieces.next()?.trim();
            if actor_id.is_empty() || keeper.is_empty() {
                None
            } else {
                Some((actor_id.to_string(), keeper.to_string()))
            }
        })
        .collect::<Vec<_>>();
    if player_keepers.is_empty() {
        return Err("player keepers가 없습니다. 새 게임에서 참가자 할당을 확인하세요.".to_string());
    }

    Ok(RoundRunPlan {
        dm_keeper,
        phase: if phase.is_empty() {
            "round".to_string()
        } else {
            phase
        },
        timeout_sec,
        lang: if lang.is_empty() {
            "ko".to_string()
        } else {
            lang
        },
        player_keepers,
    })
}
