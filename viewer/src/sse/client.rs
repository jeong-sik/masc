use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::collections::VecDeque;

use bevy::prelude::*;
use serde::Deserialize;
use serde_json::{json, Value};

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::{JsCast, JsValue};
#[cfg(target_arch = "wasm32")]
use wasm_bindgen_futures::JsFuture;
#[cfg(target_arch = "wasm32")]
use web_sys::{EventSource, MessageEvent};

#[cfg(target_arch = "wasm32")]
use crate::config;
use crate::game::state::ConnectionStatus;

use super::reconnect::{
    self, ConnectionStatusBridge, ConnectionStatusProxy, ReconnectState, SseReconnectManager,
};

/// Wrapper around `EventSource` that is `Send + Sync`.
/// Safe because WASM is single-threaded — there are no real threads to race with.
#[cfg(target_arch = "wasm32")]
struct SendEventSource(EventSource);

#[cfg(target_arch = "wasm32")]
unsafe impl Send for SendEventSource {}
#[cfg(target_arch = "wasm32")]
unsafe impl Sync for SendEventSource {}

/// Shared buffer for incoming TRPG messages.
///
/// For `LegacyEngine` mode, messages are fed by EventSource callbacks.
/// For `MascApi` mode, messages are fed by periodic JSON polling.
#[derive(Resource, Clone)]
pub struct SseReceiver {
    pub messages: Arc<Mutex<Vec<(String, String)>>>,
    polling_active: Arc<AtomicBool>,
    #[cfg(target_arch = "wasm32")]
    event_source: Arc<Mutex<Option<SendEventSource>>>,
    /// Shared reconnect state for the legacy EventSource path.
    /// Kept alive so the Arc clones in EventSource callbacks remain valid.
    #[cfg(target_arch = "wasm32")]
    #[allow(dead_code)]
    reconnect: Arc<Mutex<ReconnectState>>,
}

/// Legacy SSE event names (used only with LegacyEngine mode).
#[allow(dead_code)]
const LEGACY_SSE_EVENT_TYPES: &[&str] = &[
    "dice_roll",
    "hp_change",
    "narrative",
    "area_move",
    "turn_advance",
    "choice_available",
    "choice_resolved",
    "item_acquired",
    "character_death",
    "combat_start",
];

#[derive(Debug, Clone, Deserialize)]
#[allow(dead_code)]
struct TrpgStreamResponse {
    #[serde(default)]
    events: Vec<TrpgStreamEvent>,
}

#[derive(Debug, Clone, Deserialize)]
#[allow(dead_code)]
struct TrpgStreamEvent {
    seq: i64,
    #[serde(rename = "type")]
    event_type: String,
    #[serde(default)]
    actor_id: Option<String>,
    #[serde(default)]
    payload: Value,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
struct TrpgMapperState {
    last_turn: u32,
    last_phase: String,
    last_stream_seq: i64,
    recent_stream_fingerprints: VecDeque<String>,
    snapshot_signature: Option<String>,
}

impl Default for TrpgMapperState {
    fn default() -> Self {
        Self {
            last_turn: 1,
            last_phase: "dm_narration".to_string(),
            last_stream_seq: 0,
            recent_stream_fingerprints: VecDeque::new(),
            snapshot_signature: None,
        }
    }
}

#[allow(dead_code)]
const STREAM_FINGERPRINT_WINDOW: usize = 128;

#[allow(dead_code)]
fn value_to_i32(v: Option<&Value>, default: i32) -> i32 {
    v.and_then(Value::as_i64)
        .and_then(|n| i32::try_from(n).ok())
        .unwrap_or(default)
}

#[allow(dead_code)]
fn value_to_u32(v: Option<&Value>, default: u32) -> u32 {
    v.and_then(Value::as_u64)
        .and_then(|n| u32::try_from(n).ok())
        .unwrap_or(default)
}

#[allow(dead_code)]
fn value_to_string_vec(v: Option<&Value>) -> Vec<String> {
    match v.and_then(Value::as_array) {
        Some(xs) => xs
            .iter()
            .filter_map(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToString::to_string)
            .collect(),
        None => Vec::new(),
    }
}

#[allow(dead_code)]
fn resolve_actor_id(payload: &Value, actor_id: Option<&str>) -> String {
    payload
        .get("actor_id")
        .and_then(Value::as_str)
        .or(actor_id)
        .unwrap_or("")
    .to_string()
}

#[allow(dead_code)]
fn snapshot_fingerprint(snapshot: &Value) -> String {
    serde_json::to_string(snapshot).unwrap_or_else(|_| snapshot.to_string())
}

#[allow(dead_code)]
fn stream_event_fingerprint(event_type: &str, seq: i64, actor_id: Option<&str>, payload: &Value) -> String {
    let actor = actor_id.unwrap_or("").trim();
    format!("{seq}|{event_type}|{actor}|{payload}")
}

#[allow(dead_code)]
fn seen_stream_fingerprint(state: &TrpgMapperState, fingerprint: &str) -> bool {
    state
        .recent_stream_fingerprints
        .iter()
        .any(|entry| entry == fingerprint)
}

#[allow(dead_code)]
fn remember_stream_fingerprint(state: &mut TrpgMapperState, fingerprint: String) {
    state.recent_stream_fingerprints.push_back(fingerprint);
    while state.recent_stream_fingerprints.len() > STREAM_FINGERPRINT_WINDOW {
        let _ = state.recent_stream_fingerprints.pop_front();
    }
}

#[allow(dead_code)]
fn snapshot_root<'a>(root: &'a Value) -> &'a Value {
    root.get("state").filter(|s| !s.is_null()).unwrap_or(root)
}

#[allow(dead_code)]
fn snapshot_status(root: &Value) -> String {
    let source = snapshot_root(root);
    source
        .get("status")
        .and_then(Value::as_str)
        .or_else(|| root.get("status").and_then(Value::as_str))
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase()
}

#[allow(dead_code)]
fn snapshot_turn(root: &Value, fallback: u32) -> u32 {
    value_to_u32(snapshot_root(root).get("turn"), fallback)
}

#[allow(dead_code)]
fn snapshot_phase(root: &Value, fallback: &str) -> String {
    snapshot_root(root)
        .get("phase")
        .and_then(Value::as_str)
        .unwrap_or(fallback)
        .to_string()
}

#[allow(dead_code)]
fn snapshot_dice_entries(root: &Value) -> Vec<Value> {
    let source = root.get("dice_log").or_else(|| snapshot_root(root).get("dice_log"));
    source
        .and_then(Value::as_array)
        .map(|rows| rows.clone())
        .unwrap_or_default()
}

#[allow(dead_code)]
fn map_snapshot_result(result: &Value) -> String {
    let raw = result
        .get("label")
        .and_then(Value::as_str)
        .or_else(|| result.get("tier").and_then(Value::as_str))
        .or_else(|| result.get("result").and_then(Value::as_str))
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    match raw.as_str() {
        "critical_fail" => "critical_fail",
        "fail" => "fail",
        "partial" | "partial_success" | "부분성공" => "partial_success",
        "success" | "성공" => "success",
        "great" | "great_success" | "대성공" => "great_success",
        "miracle" | "기적" => "miracle",
        "success!" => "success",
        _ => {
            let passed = result.get("passed").and_then(Value::as_bool).unwrap_or(false);
            if passed {
                "success"
            } else {
                "fail"
            }
        }
    }
    .to_string()
}

#[allow(dead_code)]
fn map_snapshot_dice_roll(entry: &Value, fallback_turn: u32, _fallback_phase: &str) -> Option<(String, String)> {
    if !entry.is_object() {
        return None;
    }

    let character = entry
        .get("character")
        .or_else(|| entry.get("actor_id"))
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_string();
    let action = entry
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or("manual_roll")
        .to_string();
    let mapped = json!({
        "turn": value_to_u32(entry.get("turn"), fallback_turn),
        "character": character,
        "action": action,
        "d20": value_to_i32(entry.get("raw_d20"), value_to_i32(entry.get("d20"), 0)),
        "bonus": value_to_i32(entry.get("bonus"), 0),
        "total": value_to_i32(entry.get("total"), 0),
        "dc": value_to_i32(entry.get("dc"), 0),
        "result": map_snapshot_result(entry),
        "note": entry.get("note").and_then(Value::as_str).unwrap_or("")
    });
    Some(("dice_roll".to_string(), mapped.to_string()))
}

#[allow(dead_code)]
fn snapshot_room_status_progress_payload(
    root: &Value,
    status: &str,
    fallback_turn: u32,
    fallback_phase: &str,
) -> (String, String) {
    let turn = snapshot_turn(root, fallback_turn);
    let phase = snapshot_phase(root, fallback_phase);
    let event_type = match status {
        "ended" | "completed" | "done" | "retired" | "closed" => "room.ended",
        _ => "room.started",
    };
    let payload = json!({
        "event_type": event_type,
        "turn": turn,
        "phase": phase,
        "room_status": status,
        "actor_id": "",
        "keeper": "",
        "role": "",
        "reason": "",
        "dm_keeper": snapshot_root(root).get("dm_keeper").and_then(Value::as_str).unwrap_or(""),
    });
    (event_type.to_string(), payload.to_string())
}

#[allow(dead_code)]
fn map_turn_progress_event(
    event_type: &str,
    actor_id: Option<&str>,
    payload: &Value,
    state: &TrpgMapperState,
) -> Option<(String, String)> {
    let turn = value_to_u32(payload.get("turn"), state.last_turn);
    let phase = payload
        .get("phase")
        .and_then(Value::as_str)
        .unwrap_or(&state.last_phase)
        .to_string();

    let mapped = match event_type {
        "session.started" => json!({
            "event_type": event_type,
            "turn": turn,
            "phase": phase,
            "dm_keeper": payload.get("dm_keeper").and_then(Value::as_str).unwrap_or("")
        }),
        "party.selected" => json!({
            "event_type": event_type,
            "turn": turn,
            "phase": phase,
            "selected_player_ids": value_to_string_vec(payload.get("selected_player_ids"))
        }),
        "phase.changed" | "turn.started" => json!({
            "event_type": event_type,
            "turn": turn,
            "phase": phase
        }),
        "narration.posted" | "turn.action.proposed" | "turn.timeout" | "keeper.unavailable" => {
            json!({
                "event_type": event_type,
                "turn": turn,
                "phase": phase,
                "actor_id": resolve_actor_id(payload, actor_id),
                "keeper": payload.get("keeper").and_then(Value::as_str).unwrap_or(""),
                "role": payload.get("role").and_then(Value::as_str).unwrap_or(""),
                "reason": payload.get("reason").and_then(Value::as_str).unwrap_or("")
            })
        }
        "room.started" => json!({
            "event_type": event_type,
            "turn": turn,
            "phase": phase,
            "room_status": payload
                .get("room_status")
                .or_else(|| payload.get("status"))
                .and_then(Value::as_str)
                .unwrap_or("active")
        }),
        "room.ended" => json!({
            "event_type": event_type,
            "turn": turn,
            "phase": phase,
            "room_status": "ended"
        }),
        "world.event" | "scene.transition" | "quest.update" => {
            let sub = payload
                .get("event_type")
                .and_then(Value::as_str)
                .or_else(|| payload.get("title").and_then(Value::as_str))
                .unwrap_or(event_type);
            json!({
                "event_type": event_type,
                "turn": turn,
                "phase": phase,
                "reason": sub
            })
        }
        "intervention.submitted" | "intervention.applied" => {
            let itype = payload
                .get("intervention_type")
                .and_then(Value::as_str)
                .unwrap_or("");
            let reason = payload.get("reason").and_then(Value::as_str).unwrap_or("");
            let mut base = json!({
                "event_type": event_type,
                "turn": turn,
                "phase": phase,
                "reason": format!("{}: {}", itype, reason)
            });
            if let Some(aid) = actor_id {
                base["actor_id"] = json!(aid);
            }
            base
        }
        "actor.spawned" | "actor.updated" | "actor.deleted" | "actor.claimed"
        | "actor.released" => {
            let aid = payload
                .get("actor_id")
                .and_then(Value::as_str)
                .unwrap_or("");
            json!({
                "event_type": event_type,
                "turn": turn,
                "phase": phase,
                "actor_id": aid,
                "reason": event_type
            })
        }
        _ => return None,
    };

    Some(("turn_progress".to_string(), mapped.to_string()))
}

#[allow(dead_code)]
fn map_trpg_event(
    event_type: &str,
    actor_id: Option<&str>,
    payload: &Value,
    state: &mut TrpgMapperState,
) -> Vec<(String, String)> {
    let mut out = Vec::new();

    match event_type {
        "dice.rolled" => {
            let mapped = json!({
                "turn": value_to_u32(payload.get("turn"), state.last_turn),
                "character": payload.get("actor_id").and_then(Value::as_str).or(actor_id).unwrap_or("unknown"),
                "action": payload.get("action").and_then(Value::as_str).unwrap_or("action"),
                "d20": value_to_i32(payload.get("raw_d20"), 0),
                "bonus": value_to_i32(payload.get("bonus"), 0),
                "total": value_to_i32(payload.get("total"), 0),
                "dc": value_to_i32(payload.get("dc"), 0),
                "result": payload.get("label").and_then(Value::as_str).unwrap_or("unknown")
            });
            out.push(("dice_roll".to_string(), mapped.to_string()));
        }
        "hp.changed" => {
            let mapped = json!({
                "target": payload.get("target").and_then(Value::as_str).or(actor_id).unwrap_or("unknown"),
                "amount": value_to_i32(payload.get("amount"), 0),
                "remaining_hp": value_to_i32(payload.get("remaining_hp"), 0),
                "source": payload.get("source").and_then(Value::as_str).unwrap_or("system")
            });
            out.push(("hp_change".to_string(), mapped.to_string()));
        }
        "narration.posted" => {
            let text = payload
                .get("text")
                .and_then(Value::as_str)
                .or_else(|| payload.get("reply").and_then(Value::as_str))
                .unwrap_or("");
            let mapped = json!({
                "text": text,
                "phase": payload.get("phase").and_then(Value::as_str).unwrap_or(&state.last_phase),
                "speaker": payload
                    .get("speaker")
                    .and_then(Value::as_str)
                    .or_else(|| payload.get("actor_id").and_then(Value::as_str))
                    .or(actor_id)
                    .or_else(|| payload.get("keeper").and_then(Value::as_str))
            });
            out.push(("narrative".to_string(), mapped.to_string()));
        }
        "turn.action.proposed" => {
            let proposed = payload
                .get("proposed_action")
                .and_then(Value::as_str)
                .or_else(|| payload.get("reply").and_then(Value::as_str))
                .unwrap_or("action proposed");
            let mapped = json!({
                "text": proposed,
                "phase": payload.get("phase").and_then(Value::as_str).unwrap_or(&state.last_phase),
                "speaker": payload
                    .get("actor_id")
                    .and_then(Value::as_str)
                    .or(actor_id)
            });
            out.push(("narrative".to_string(), mapped.to_string()));
        }
        "turn.timeout" => {
            let actor = payload
                .get("actor_id")
                .and_then(Value::as_str)
                .or(actor_id)
                .unwrap_or("unknown");
            let timeout = payload.get("timeout_sec").and_then(Value::as_f64);
            let text = match timeout {
                Some(sec) => format!("[timeout] {} ({}s)", actor, sec.round()),
                None => format!("[timeout] {}", actor),
            };
            let mapped = json!({
                "text": text,
                "phase": payload.get("phase").and_then(Value::as_str).unwrap_or(&state.last_phase),
                "speaker": payload.get("keeper").and_then(Value::as_str)
            });
            out.push(("narrative".to_string(), mapped.to_string()));
        }
        "keeper.unavailable" => {
            let actor = payload
                .get("actor_id")
                .and_then(Value::as_str)
                .or(actor_id)
                .unwrap_or("unknown");
            let reason = payload
                .get("reason")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let mapped = json!({
                "text": format!("[unavailable] {}: {}", actor, reason),
                "phase": payload.get("phase").and_then(Value::as_str).unwrap_or(&state.last_phase),
                "speaker": payload.get("keeper").and_then(Value::as_str)
            });
            out.push(("narrative".to_string(), mapped.to_string()));
        }
        "turn.started" => {
            let turn = value_to_u32(payload.get("turn"), state.last_turn);
            if turn > 0 {
                state.last_turn = turn;
            }
            let phase = payload
                .get("phase")
                .and_then(Value::as_str)
                .unwrap_or(&state.last_phase)
                .to_string();
            if !phase.is_empty() {
                state.last_phase = phase.clone();
            }
            let mapped = json!({
                "turn": state.last_turn,
                "phase": state.last_phase
            });
            out.push(("turn_advance".to_string(), mapped.to_string()));
        }
        "phase.changed" => {
            let phase = payload
                .get("phase")
                .and_then(Value::as_str)
                .unwrap_or(&state.last_phase)
                .to_string();
            if !phase.is_empty() {
                state.last_phase = phase.clone();
            }
            let turn = value_to_u32(payload.get("turn"), state.last_turn);
            if turn > 0 {
                state.last_turn = turn;
            }
            let mapped = json!({
                "turn": state.last_turn,
                "phase": state.last_phase
            });
            out.push(("turn_advance".to_string(), mapped.to_string()));
        }
        "node.advanced" => {
            let mapped = json!({
                "character": payload.get("character").and_then(Value::as_str).or(actor_id).unwrap_or("party"),
                "from_area": payload.get("from_area").and_then(Value::as_str).unwrap_or(""),
                "to_area": payload.get("to_area").and_then(Value::as_str).unwrap_or(""),
            });
            out.push(("area_move".to_string(), mapped.to_string()));
        }
        "inventory.changed" => {
            let mapped = json!({
                "character": payload.get("character").and_then(Value::as_str).or(actor_id).unwrap_or("unknown"),
                "item": payload.get("item").and_then(Value::as_str).unwrap_or("item")
            });
            out.push(("item_acquired".to_string(), mapped.to_string()));
        }
        "turn.action.resolved" => {
            let narrative = payload
                .get("story_log")
                .and_then(Value::as_array)
                .and_then(|arr| arr.first())
                .and_then(Value::as_str)
                .or_else(|| payload.get("result").and_then(Value::as_str))
                .unwrap_or("action resolved");
            let mapped = json!({
                "text": narrative,
                "phase": state.last_phase,
                "speaker": actor_id
            });
            out.push(("narrative".to_string(), mapped.to_string()));
        }
        // -- world.event: dispatch to weather/mood/death based on subtype --
        "world.event" => {
            let sub = payload
                .get("event_type")
                .and_then(Value::as_str)
                .unwrap_or("");
            let desc = payload
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or("");
            if sub.contains("weather") {
                let mapped = json!({ "weather": desc });
                out.push(("weather_change".to_string(), mapped.to_string()));
            } else if sub.contains("mood") || sub.contains("atmosphere") {
                let mapped = json!({ "mood": desc });
                out.push(("mood_change".to_string(), mapped.to_string()));
            } else if sub.contains("death") || sub.contains("died") || sub.contains("kill") {
                let actor = resolve_actor_id(payload, actor_id);
                let mapped = json!({
                    "character": actor,
                    "cause": desc,
                });
                out.push(("character_death".to_string(), mapped.to_string()));
            } else {
                let mapped = json!({
                    "text": format!("[world] {}", desc),
                    "phase": state.last_phase,
                });
                out.push(("narrative".to_string(), mapped.to_string()));
            }
        }
        // -- scene.transition → area_move --
        "scene.transition" => {
            let from = payload
                .get("from_scene")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let to = payload
                .get("to_scene")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let trigger = payload.get("trigger").and_then(Value::as_str).unwrap_or("");
            let mapped = json!({
                "character": trigger,
                "from_area": from,
                "to_area": to,
            });
            out.push(("area_move".to_string(), mapped.to_string()));
        }
        // -- quest.update → narrative --
        "quest.update" => {
            let title = payload
                .get("title")
                .and_then(Value::as_str)
                .unwrap_or("unknown quest");
            let status = payload
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("updated");
            let mapped = json!({
                "text": format!("[quest] {} \u{2014} {}", title, status),
                "phase": state.last_phase,
            });
            out.push(("narrative".to_string(), mapped.to_string()));
        }
        // -- intervention.submitted / applied → narrative --
        "intervention.submitted" | "intervention.applied" => {
            let itype = payload
                .get("intervention_type")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let reason = payload.get("reason").and_then(Value::as_str).unwrap_or("");
            let status_label = if event_type == "intervention.applied" {
                "applied"
            } else {
                "pending"
            };
            let mapped = json!({
                "text": format!("[intervention:{}] {} \u{2014} {}", status_label, itype, reason),
                "phase": state.last_phase,
            });
            out.push(("narrative".to_string(), mapped.to_string()));
        }
        // -- choice.available → choice_available --
        "choice.available" => {
            let mapped = json!({
                "character": payload.get("actor_id").and_then(Value::as_str)
                    .or(actor_id).unwrap_or("unknown"),
                "description": payload.get("description").and_then(Value::as_str).unwrap_or(""),
                "options": payload.get("options").and_then(Value::as_array)
                    .cloned().unwrap_or_default()
            });
            out.push(("choice_available".to_string(), mapped.to_string()));
        }
        // -- choice.resolved → choice_resolved --
        "choice.resolved" => {
            let mapped = json!({
                "character": payload.get("actor_id").and_then(Value::as_str)
                    .or(actor_id).unwrap_or("unknown"),
                "description": payload.get("chosen").and_then(Value::as_str).unwrap_or(""),
                "options": []
            });
            out.push(("choice_resolved".to_string(), mapped.to_string()));
        }
        // -- combat.started → combat_start --
        "combat.started" => {
            let mapped = json!({
                "area": payload.get("area").and_then(Value::as_str).unwrap_or("unknown"),
                "enemies": payload.get("enemies").and_then(Value::as_array)
                    .cloned().unwrap_or_default()
            });
            out.push(("combat_start".to_string(), mapped.to_string()));
        }
        // -- game.ended / quest.completed → narrative with endgame phase --
        "game.ended" | "quest.completed" => {
            let text = payload.get("summary").and_then(Value::as_str)
                .or_else(|| payload.get("text").and_then(Value::as_str))
                .unwrap_or("The adventure has ended.");
            let mapped = json!({ "text": text, "phase": "endgame", "speaker": "DM" });
            out.push(("narrative".to_string(), mapped.to_string()));
        }
        // -- actor lifecycle → turn_progress only (handled below) --
        "actor.spawned" | "actor.updated" | "actor.deleted" | "actor.claimed"
        | "actor.released" => {
            // No primary event; lifecycle tracked via turn_progress
        }
        // -- Phase 1 lifecycle: pass raw payload to bridge as-is --
        "party.selected" | "room.created" | "room.started" | "session.started" => {
            out.push((event_type.to_string(), payload.to_string()));
        }
        _ => {}
    }

    if let Some(progress) = map_turn_progress_event(event_type, actor_id, payload, state) {
        out.push(progress);
    }

    out
}

#[allow(dead_code)]
fn decode_snapshot_events(
    body: &Value,
    state: &mut TrpgMapperState,
) -> Vec<(String, String)> {
    let status = snapshot_status(body);
    let signature = snapshot_fingerprint(body);
    if state.snapshot_signature.as_deref() == Some(signature.as_str()) {
        return Vec::new();
    }
    state.snapshot_signature = Some(signature);

    let status = if status.is_empty() {
        "unknown".to_string()
    } else {
        status
    };
    let turn = snapshot_turn(body, state.last_turn);
    if turn > 0 {
        state.last_turn = turn;
    }
    let phase = snapshot_phase(body, &state.last_phase);
    if !phase.is_empty() {
        state.last_phase = phase.clone();
    }

    let mut out = Vec::new();

    out.push(snapshot_room_status_progress_payload(
        body,
        &status,
        turn,
        &phase,
    ));

    if turn > 0 {
        out.push((
            "turn_advance".to_string(),
            json!({ "turn": turn, "phase": phase.clone() }).to_string(),
        ));
    }

    for entry in snapshot_dice_entries(body) {
        if let Some(mapped) = map_snapshot_dice_roll(&entry, turn, &phase) {
            out.push(mapped);
        }
    }

    out
}

#[allow(dead_code)]
fn decode_stream_events(
    body: &str,
    state: &mut TrpgMapperState,
) -> Result<(i64, Vec<(String, String)>), String> {
    let parsed: Value = serde_json::from_str(body).map_err(|e| e.to_string())?;

    if parsed.get("events").is_some() {
        let parsed: TrpgStreamResponse =
            serde_json::from_value(parsed).map_err(|e| e.to_string())?;
        let mut max_seq = 0_i64;
        let mut out = Vec::new();

        for ev in parsed.events {
            if ev.seq > max_seq {
                max_seq = ev.seq;
            }
            let fingerprint = stream_event_fingerprint(
                &ev.event_type,
                ev.seq,
                ev.actor_id.as_deref(),
                &ev.payload,
            );
            if ev.seq > 0 && ev.seq <= state.last_stream_seq {
                #[cfg(target_arch = "wasm32")]
                bump_dedup_stream(&format!("seq {} <= {}", ev.seq, state.last_stream_seq));
                remember_stream_fingerprint(state, fingerprint);
                continue;
            }
            if seen_stream_fingerprint(state, &fingerprint) {
                #[cfg(target_arch = "wasm32")]
                bump_dedup_stream(&format!("fp | {} | seq {}", ev.event_type, ev.seq));
                continue;
            }
            if ev.seq > 0 {
                state.last_stream_seq = state.last_stream_seq.max(ev.seq);
            }
            out.extend(map_trpg_event(
                &ev.event_type,
                ev.actor_id.as_deref(),
                &ev.payload,
                state,
            ));
            remember_stream_fingerprint(state, fingerprint);
        }
        if max_seq > 0 {
            state.last_stream_seq = state.last_stream_seq.max(max_seq);
        }

        return Ok((max_seq, out));
    }

    let out = decode_snapshot_events(&parsed, state);
    let max_seq = 0_i64;
    Ok((max_seq, out))
}

#[cfg(target_arch = "wasm32")]
fn bump_dedup_stream(sample: &str) {
    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(dashboard) = document.get_element_by_id("dashboard") else {
        return;
    };
    let next = dashboard
        .get_attribute("data-dedup-stream")
        .and_then(|raw| raw.parse::<u64>().ok())
        .unwrap_or(0)
        .saturating_add(1);
    let _ = dashboard.set_attribute("data-dedup-stream", &next.to_string());

    let mut lines = dashboard
        .get_attribute("data-dedup-samples-stream")
        .unwrap_or_default()
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    let trimmed = sample.trim();
    if !trimmed.is_empty() {
        lines.push(trimmed.chars().take(160).collect());
    }
    if lines.len() > 24 {
        let drain = lines.len() - 24;
        lines.drain(0..drain);
    }
    let _ = dashboard.set_attribute("data-dedup-samples-stream", &lines.join("\n"));
}

#[cfg(target_arch = "wasm32")]
async fn fetch_text(url: &str) -> Result<String, JsValue> {
    let opts = web_sys::RequestInit::new();
    opts.set_method("GET");
    opts.set_mode(web_sys::RequestMode::Cors);

    let request = web_sys::Request::new_with_str_and_init(url, &opts)?;
    request.headers().set("Accept", "application/json")?;

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;
    if !resp.ok() {
        return Err(JsValue::from_str(&format!("HTTP {}", resp.status())));
    }
    let text = JsFuture::from(resp.text()?).await?;
    Ok(text.as_string().unwrap_or_default())
}

#[cfg(target_arch = "wasm32")]
async fn sleep_ms(ms: i32) -> Result<(), JsValue> {
    let promise = js_sys::Promise::new(&mut |resolve, _reject| {
        if let Some(window) = web_sys::window() {
            let _ = window
                .set_timeout_with_callback_and_timeout_and_arguments_0(resolve.unchecked_ref(), ms);
        } else {
            let _ = resolve.call0(&JsValue::NULL);
        }
    });
    let _ = JsFuture::from(promise).await?;
    Ok(())
}

#[cfg(target_arch = "wasm32")]
async fn bootstrap_after_seq(state: &mut TrpgMapperState) -> i64 {
    let bootstrap_url = config::trpg_stream_poll_url(0);
    match fetch_text(&bootstrap_url).await {
        Ok(body) => match decode_stream_events(&body, state) {
            Ok((max_seq, _)) => {
                let seq = max_seq.max(0);
                if seq > 0 {
                    log::info!(
                        "TRPG poll bootstrap: skipping historical events up to seq {}",
                        seq
                    );
                }
                seq
            }
            Err(e) => {
                log::warn!("Failed to decode TRPG bootstrap payload: {}", e);
                0
            }
        },
        Err(e) => {
            log::debug!("TRPG bootstrap request failed: {:?}", e);
            0
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn start_polling_loop(messages: Arc<Mutex<Vec<(String, String)>>>, active: Arc<AtomicBool>) {
    wasm_bindgen_futures::spawn_local(async move {
        let mut state = TrpgMapperState::default();
        let mut active_room = config::current_room_id();
        let mut after_seq = bootstrap_after_seq(&mut state).await;

        while active.load(Ordering::Relaxed) {
            let room_now = config::current_room_id();
            if room_now != active_room {
                active_room = room_now.clone();
                state = TrpgMapperState::default();
                after_seq = bootstrap_after_seq(&mut state).await;
                log::info!("TRPG poll room switched: {}", room_now);
            }
            let url = config::trpg_stream_poll_url(after_seq);
            match fetch_text(&url).await {
                Ok(body) => match decode_stream_events(&body, &mut state) {
                    Ok((max_seq, mapped)) => {
                        if max_seq > after_seq {
                            after_seq = max_seq;
                        }
                        if !mapped.is_empty() {
                            if let Ok(mut buf) = messages.lock() {
                                buf.extend(mapped);
                            }
                        }
                    }
                    Err(e) => {
                        log::warn!("Failed to decode TRPG stream payload: {}", e);
                    }
                },
                Err(e) => {
                    log::debug!("TRPG poll request failed: {:?}", e);
                }
            }

            if sleep_ms(500).await.is_err() {
                break;
            }
        }
    });
}

/// Create a legacy EventSource with reconnect support.
#[cfg(target_arch = "wasm32")]
fn create_legacy_event_source(
    url: &str,
    messages: Arc<Mutex<Vec<(String, String)>>>,
    es_handle: Arc<Mutex<Option<SendEventSource>>>,
    reconnect_state: Arc<Mutex<ReconnectState>>,
    status_proxy: Arc<Mutex<ConnectionStatusProxy>>,
) {
    let es = match EventSource::new(url) {
        Ok(es) => es,
        Err(e) => {
            log::warn!("Failed to create EventSource at {}: {:?}", url, e);
            attempt_trpg_reconnect(messages, es_handle, reconnect_state, status_proxy);
            return;
        }
    };

    for &event_type in LEGACY_SSE_EVENT_TYPES {
        let msgs = messages.clone();
        let etype = event_type.to_string();
        let rs = reconnect_state.clone();
        let callback = Closure::<dyn FnMut(MessageEvent)>::new(move |e: MessageEvent| {
            if let Some(data) = e.data().as_string() {
                if let Ok(mut buf) = msgs.lock() {
                    buf.push((etype.clone(), data));
                }
            }
            let event_id = e.last_event_id();
            if !event_id.is_empty() {
                if let Ok(mut state) = rs.lock() {
                    state.record_event_id(&event_id);
                }
            }
        });
        let _ = es.add_event_listener_with_callback(event_type, callback.as_ref().unchecked_ref());
        callback.forget();
    }

    {
        let connected_url = url.to_string();
        let rs = reconnect_state.clone();
        let sp = status_proxy.clone();
        let callback = Closure::<dyn FnMut()>::new(move || {
            log::info!("Legacy TRPG SSE connected to {}", connected_url);
            if let Ok(mut state) = rs.lock() {
                state.reset();
            }
            if let Ok(mut proxy) = sp.lock() {
                proxy.set(ConnectionStatus::Connected);
            }
        });
        es.set_onopen(Some(callback.as_ref().unchecked_ref()));
        callback.forget();
    }

    {
        let msgs = messages.clone();
        let esh = es_handle.clone();
        let rs = reconnect_state.clone();
        let sp = status_proxy.clone();
        let callback = Closure::<dyn FnMut()>::new(move || {
            log::warn!("Legacy TRPG SSE connection error — scheduling reconnect");
            if let Ok(guard) = esh.lock() {
                if let Some(es) = guard.as_ref() {
                    es.0.close();
                }
            }
            attempt_trpg_reconnect(msgs.clone(), esh.clone(), rs.clone(), sp.clone());
        });
        es.set_onerror(Some(callback.as_ref().unchecked_ref()));
        callback.forget();
    }

    if let Ok(mut guard) = es_handle.lock() {
        *guard = Some(SendEventSource(es));
    }
}

/// Attempt TRPG legacy EventSource reconnection with backoff.
#[cfg(target_arch = "wasm32")]
fn attempt_trpg_reconnect(
    messages: Arc<Mutex<Vec<(String, String)>>>,
    es_handle: Arc<Mutex<Option<SendEventSource>>>,
    reconnect_state: Arc<Mutex<ReconnectState>>,
    status_proxy: Arc<Mutex<ConnectionStatusProxy>>,
) {
    let (delay, attempt, max_retries, last_event_id) = {
        let mut state = match reconnect_state.lock() {
            Ok(s) => s,
            Err(_) => return,
        };
        match state.next_delay() {
            Some(d) => (
                d,
                state.attempt,
                state.max_retries,
                state.last_event_id.clone(),
            ),
            None => {
                log::error!(
                    "TRPG SSE reconnect exhausted ({} attempts) — giving up",
                    state.max_retries
                );
                if let Ok(mut proxy) = status_proxy.lock() {
                    proxy.set(ConnectionStatus::Failed);
                }
                return;
            }
        }
    };

    log::info!(
        "TRPG SSE reconnect attempt {}/{} in {}ms",
        attempt,
        max_retries,
        delay
    );

    reconnect::schedule_reconnect(
        delay,
        attempt,
        max_retries,
        status_proxy.clone(),
        move || {
            let base_url = config::trpg_stream_poll_url(0);
            let url = reconnect::url_with_last_event_id(&base_url, &last_event_id);
            create_legacy_event_source(&url, messages, es_handle, reconnect_state, status_proxy);
        },
    );
}

/// Startup system that creates TRPG stream input (polling or legacy EventSource).
#[cfg(target_arch = "wasm32")]
pub fn setup_sse(
    mut commands: Commands,
    mut connection: ResMut<ConnectionStatus>,
    bridge: Res<ConnectionStatusBridge>,
    mut reconnect_mgr: ResMut<SseReconnectManager>,
) {
    *connection = ConnectionStatus::Connecting;
    let messages = Arc::new(Mutex::new(Vec::new()));
    let active = Arc::new(AtomicBool::new(true));
    let es_handle: Arc<Mutex<Option<SendEventSource>>> = Arc::new(Mutex::new(None));

    // Reset TRPG reconnect state
    reconnect_mgr.trpg = ReconnectState::default();
    let reconnect_state = Arc::new(Mutex::new(reconnect_mgr.trpg.clone()));

    if config::trpg_uses_polling() {
        start_polling_loop(messages.clone(), active.clone());
        commands.insert_resource(SseReceiver {
            messages,
            polling_active: active,
            event_source: es_handle,
            reconnect: reconnect_state,
        });
        log::info!(
            "TRPG poll client initialized: {}",
            config::trpg_stream_poll_url(0)
        );
        return;
    }

    let url = config::trpg_stream_poll_url(0);

    create_legacy_event_source(
        &url,
        messages.clone(),
        es_handle.clone(),
        reconnect_state.clone(),
        bridge.proxy.clone(),
    );

    commands.insert_resource(SseReceiver {
        messages,
        polling_active: active,
        event_source: es_handle,
        reconnect: reconnect_state,
    });
}

/// Native no-op for setup_sse.
#[cfg(not(target_arch = "wasm32"))]
pub fn setup_sse(
    mut _commands: Commands,
    mut _connection: ResMut<ConnectionStatus>,
    _bridge: Res<ConnectionStatusBridge>,
    _reconnect_mgr: ResMut<SseReconnectManager>,
) {
}

/// OnExit(Trpg) system: stops polling, closes EventSource, and removes resource.
pub fn teardown_sse(
    mut commands: Commands,
    receiver: Option<Res<SseReceiver>>,
    connection: Option<ResMut<ConnectionStatus>>,
) {
    if let Some(recv) = receiver {
        recv.polling_active.store(false, Ordering::Relaxed);
        #[cfg(target_arch = "wasm32")]
        {
            if let Ok(guard) = recv.event_source.lock() {
                if let Some(es) = guard.as_ref() {
                    es.0.close();
                    log::info!("Legacy TRPG EventSource closed");
                }
            }
        }
    }
    if let Some(mut status) = connection {
        *status = ConnectionStatus::Disconnected;
    }
    commands.remove_resource::<SseReceiver>();
    log::info!("SseReceiver resource removed");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_stream_maps_turn_and_dice_events() {
        let body = r#"{
            "ok": true,
            "events": [
                {"seq": 1, "type": "phase.changed", "payload": {"phase": "player_action"}},
                {"seq": 2, "type": "turn.started", "payload": {"turn": 3}},
                {"seq": 3, "type": "dice.rolled", "actor_id": "grimja", "payload": {"action":"attack","raw_d20":17,"bonus":3,"total":20,"dc":15,"label":"success"}}
            ]
        }"#;
        let mut state = TrpgMapperState::default();
        let (max_seq, mapped) =
            decode_stream_events(body, &mut state).expect("decode should succeed");

        assert_eq!(max_seq, 3);
        let turn_events: Vec<&(String, String)> = mapped
            .iter()
            .filter(|(event_type, _)| event_type == "turn_advance")
            .collect();
        assert_eq!(turn_events.len(), 2);
        let dice_event = mapped
            .iter()
            .find(|(event_type, _)| event_type == "dice_roll")
            .expect("dice_roll should exist");
        let progress_events: Vec<&(String, String)> = mapped
            .iter()
            .filter(|(event_type, _)| event_type == "turn_progress")
            .collect();
        assert_eq!(progress_events.len(), 2);

        let turn_payload: Value =
            serde_json::from_str(&turn_events[1].1).expect("turn payload json");
        assert_eq!(turn_payload["turn"], 3);
        assert_eq!(turn_payload["phase"], "player_action");

        let dice_payload: Value = serde_json::from_str(&dice_event.1).expect("dice payload json");
        assert_eq!(dice_payload["character"], "grimja");
        assert_eq!(dice_payload["d20"], 17);
    }

    #[test]
    fn decode_stream_maps_action_resolved_to_narrative() {
        let body = r#"{
            "events": [
                {"seq": 1, "type": "turn.action.resolved", "actor_id": "dm", "payload": {"story_log": ["문이 열린다", "빛이 새어 나온다"]}}
            ]
        }"#;
        let mut state = TrpgMapperState::default();
        let (_, mapped) = decode_stream_events(body, &mut state).expect("decode should succeed");
        let narrative_event = mapped
            .iter()
            .find(|(event_type, _)| event_type == "narrative")
            .expect("narrative should exist");

        let payload: Value =
            serde_json::from_str(&narrative_event.1).expect("narrative payload json");
        assert_eq!(payload["text"], "문이 열린다");
        assert_eq!(payload["speaker"], "dm");
    }

    #[test]
    fn decode_stream_maps_narration_reply_field() {
        let body = r#"{
            "events": [
                {"seq": 1, "type": "narration.posted", "actor_id": "dm", "payload": {"phase": "round", "keeper": "dm-keeper", "reply": "안개가 짙어집니다."}}
            ]
        }"#;
        let mut state = TrpgMapperState::default();
        let (_, mapped) = decode_stream_events(body, &mut state).expect("decode should succeed");
        let narrative_event = mapped
            .iter()
            .find(|(event_type, _)| event_type == "narrative")
            .expect("narrative should exist");

        let payload: Value =
            serde_json::from_str(&narrative_event.1).expect("narrative payload json");
        assert_eq!(payload["text"], "안개가 짙어집니다.");
        assert_eq!(payload["speaker"], "dm");

        let progress_event = mapped
            .iter()
            .find(|(event_type, _)| event_type == "turn_progress")
            .expect("turn_progress should exist");
        let progress_payload: Value =
            serde_json::from_str(&progress_event.1).expect("turn_progress payload json");
        assert_eq!(progress_payload["event_type"], "narration.posted");
        assert_eq!(progress_payload["actor_id"], "dm");
    }

    #[test]
    fn decode_stream_maps_timeout_and_unavailable_to_narrative() {
        let body = r#"{
            "events": [
                {"seq": 1, "type": "turn.timeout", "payload": {"actor_id": "p01", "keeper": "pk-p01", "timeout_sec": 90, "phase": "round"}},
                {"seq": 2, "type": "keeper.unavailable", "payload": {"actor_id": "p02", "keeper": "pk-p02", "reason": "LLM failed", "phase": "round"}}
            ]
        }"#;
        let mut state = TrpgMapperState::default();
        let (_, mapped) = decode_stream_events(body, &mut state).expect("decode should succeed");
        let narrative_events: Vec<&(String, String)> = mapped
            .iter()
            .filter(|(event_type, _)| event_type == "narrative")
            .collect();
        assert_eq!(narrative_events.len(), 2);
        let progress_events: Vec<&(String, String)> = mapped
            .iter()
            .filter(|(event_type, _)| event_type == "turn_progress")
            .collect();
        assert_eq!(progress_events.len(), 2);

        let timeout_payload: Value =
            serde_json::from_str(&narrative_events[0].1).expect("timeout narrative payload json");
        assert!(timeout_payload["text"]
            .as_str()
            .unwrap_or_default()
            .contains("[timeout] p01"));

        let unavailable_payload: Value = serde_json::from_str(&narrative_events[1].1)
            .expect("unavailable narrative payload json");
        assert_eq!(unavailable_payload["text"], "[unavailable] p02: LLM failed");
    }

    #[test]
    fn decode_stream_maps_choice_and_combat_events() {
        let body = r#"{
            "events": [
                {"seq": 1, "type": "choice.available", "payload": {"actor_id": "elf_01", "description": "Choose your path", "options": ["Fight", "Flee"]}},
                {"seq": 2, "type": "choice.resolved", "payload": {"actor_id": "elf_01", "chosen": "Fight"}},
                {"seq": 3, "type": "combat.started", "payload": {"area": "Dark Cave", "enemies": ["Goblin", "Orc"]}}
            ]
        }"#;
        let mut state = TrpgMapperState::default();
        let (max_seq, mapped) =
            decode_stream_events(body, &mut state).expect("decode should succeed");

        assert_eq!(max_seq, 3);

        let choice_available = mapped
            .iter()
            .find(|(event_type, _)| event_type == "choice_available")
            .expect("choice_available should exist");
        let ca_payload: Value =
            serde_json::from_str(&choice_available.1).expect("choice_available payload json");
        assert_eq!(ca_payload["character"], "elf_01");
        assert_eq!(ca_payload["description"], "Choose your path");
        assert_eq!(ca_payload["options"], json!(["Fight", "Flee"]));

        let choice_resolved = mapped
            .iter()
            .find(|(event_type, _)| event_type == "choice_resolved")
            .expect("choice_resolved should exist");
        let cr_payload: Value =
            serde_json::from_str(&choice_resolved.1).expect("choice_resolved payload json");
        assert_eq!(cr_payload["character"], "elf_01");
        assert_eq!(cr_payload["description"], "Fight");

        let combat_start = mapped
            .iter()
            .find(|(event_type, _)| event_type == "combat_start")
            .expect("combat_start should exist");
        let cs_payload: Value =
            serde_json::from_str(&combat_start.1).expect("combat_start payload json");
        assert_eq!(cs_payload["area"], "Dark Cave");
        assert_eq!(cs_payload["enemies"], json!(["Goblin", "Orc"]));
    }

    #[test]
    fn decode_stream_maps_lifecycle_and_endgame_events() {
        let body = r#"{
            "events": [
                {"seq": 1, "type": "game.ended", "payload": {"summary": "Victory!"}},
                {"seq": 2, "type": "party.selected", "payload": {"player_ids": ["p1", "p2"]}},
                {"seq": 3, "type": "room.created", "payload": {"room_id": "r1"}}
            ]
        }"#;
        let mut state = TrpgMapperState::default();
        let (max_seq, mapped) =
            decode_stream_events(body, &mut state).expect("decode should succeed");

        assert_eq!(max_seq, 3);

        let narrative = mapped
            .iter()
            .find(|(event_type, _)| event_type == "narrative")
            .expect("narrative should exist");
        let n_payload: Value =
            serde_json::from_str(&narrative.1).expect("narrative payload json");
        assert_eq!(n_payload["text"], "Victory!");
        assert_eq!(n_payload["phase"], "endgame");

        let party = mapped
            .iter()
            .find(|(event_type, _)| event_type == "party.selected")
            .expect("party.selected should exist");
        let p_payload: Value =
            serde_json::from_str(&party.1).expect("party.selected payload json");
        assert_eq!(p_payload["player_ids"], json!(["p1", "p2"]));

        let room = mapped
            .iter()
            .find(|(event_type, _)| event_type == "room.created")
            .expect("room.created should exist");
        let r_payload: Value =
            serde_json::from_str(&room.1).expect("room.created payload json");
        assert_eq!(r_payload["room_id"], "r1");
    }
}
