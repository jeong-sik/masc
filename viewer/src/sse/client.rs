use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

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
struct TrpgStreamResponse {
    #[serde(default)]
    events: Vec<TrpgStreamEvent>,
}

#[derive(Debug, Clone, Deserialize)]
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
struct TrpgMapperState {
    last_turn: u32,
    last_phase: String,
}

impl Default for TrpgMapperState {
    fn default() -> Self {
        Self {
            last_turn: 1,
            last_phase: "dm_narration".to_string(),
        }
    }
}

fn value_to_i32(v: Option<&Value>, default: i32) -> i32 {
    v.and_then(Value::as_i64)
        .and_then(|n| i32::try_from(n).ok())
        .unwrap_or(default)
}

fn value_to_u32(v: Option<&Value>, default: u32) -> u32 {
    v.and_then(Value::as_u64)
        .and_then(|n| u32::try_from(n).ok())
        .unwrap_or(default)
}

fn map_trpg_event(
    event_type: &str,
    actor_id: Option<&str>,
    payload: &Value,
    state: &mut TrpgMapperState,
) -> Option<(String, String)> {
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
            Some(("dice_roll".to_string(), mapped.to_string()))
        }
        "hp.changed" => {
            let mapped = json!({
                "target": payload.get("target").and_then(Value::as_str).or(actor_id).unwrap_or("unknown"),
                "amount": value_to_i32(payload.get("amount"), 0),
                "remaining_hp": value_to_i32(payload.get("remaining_hp"), 0),
                "source": payload.get("source").and_then(Value::as_str).unwrap_or("system")
            });
            Some(("hp_change".to_string(), mapped.to_string()))
        }
        "narration.posted" => {
            let mapped = json!({
                "text": payload.get("text").and_then(Value::as_str).unwrap_or(""),
                "phase": payload.get("phase").and_then(Value::as_str).unwrap_or(&state.last_phase),
                "speaker": payload.get("speaker").and_then(Value::as_str)
            });
            Some(("narrative".to_string(), mapped.to_string()))
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
            Some(("turn_advance".to_string(), mapped.to_string()))
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
            Some(("turn_advance".to_string(), mapped.to_string()))
        }
        "node.advanced" => {
            let mapped = json!({
                "character": payload.get("character").and_then(Value::as_str).or(actor_id).unwrap_or("party"),
                "from_area": payload.get("from_area").and_then(Value::as_str).unwrap_or(""),
                "to_area": payload.get("to_area").and_then(Value::as_str).unwrap_or(""),
            });
            Some(("area_move".to_string(), mapped.to_string()))
        }
        "inventory.changed" => {
            let mapped = json!({
                "character": payload.get("character").and_then(Value::as_str).or(actor_id).unwrap_or("unknown"),
                "item": payload.get("item").and_then(Value::as_str).unwrap_or("item")
            });
            Some(("item_acquired".to_string(), mapped.to_string()))
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
            Some(("narrative".to_string(), mapped.to_string()))
        }
        _ => None,
    }
}

fn decode_stream_events(
    body: &str,
    state: &mut TrpgMapperState,
) -> Result<(i64, Vec<(String, String)>), String> {
    let parsed: TrpgStreamResponse = serde_json::from_str(body).map_err(|e| e.to_string())?;
    let mut max_seq = 0_i64;
    let mut out = Vec::new();

    for ev in parsed.events {
        if ev.seq > max_seq {
            max_seq = ev.seq;
        }
        if let Some(mapped) =
            map_trpg_event(&ev.event_type, ev.actor_id.as_deref(), &ev.payload, state)
        {
            out.push(mapped);
        }
    }

    Ok((max_seq, out))
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
fn start_polling_loop(messages: Arc<Mutex<Vec<(String, String)>>>, active: Arc<AtomicBool>) {
    wasm_bindgen_futures::spawn_local(async move {
        let mut after_seq = 0_i64;
        let mut state = TrpgMapperState::default();

        while active.load(Ordering::Relaxed) {
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

            if sleep_ms(config::TRPG_POLL_INTERVAL_MS).await.is_err() {
                break;
            }
        }
    });
}

/// Startup system that creates TRPG stream input (polling or legacy EventSource).
#[cfg(target_arch = "wasm32")]
pub fn setup_sse(mut commands: Commands) {
    let messages = Arc::new(Mutex::new(Vec::new()));
    let active = Arc::new(AtomicBool::new(true));
    let es_handle: Arc<Mutex<Option<SendEventSource>>> = Arc::new(Mutex::new(None));

    if config::trpg_uses_polling() {
        start_polling_loop(messages.clone(), active.clone());
        commands.insert_resource(SseReceiver {
            messages,
            polling_active: active,
            event_source: es_handle,
        });
        log::info!(
            "TRPG poll client initialized: {}",
            config::trpg_stream_poll_url(0)
        );
        return;
    }

    let url = config::trpg_stream_poll_url(0);
    let es = match EventSource::new(&url) {
        Ok(es) => es,
        Err(e) => {
            log::warn!("Failed to create EventSource at {}: {:?}", url, e);
            commands.insert_resource(SseReceiver {
                messages,
                polling_active: active,
                event_source: es_handle,
            });
            return;
        }
    };

    for &event_type in LEGACY_SSE_EVENT_TYPES {
        let msgs = messages.clone();
        let etype = event_type.to_string();
        let callback = Closure::<dyn FnMut(MessageEvent)>::new(move |e: MessageEvent| {
            if let Some(data) = e.data().as_string() {
                if let Ok(mut buf) = msgs.lock() {
                    buf.push((etype.clone(), data));
                }
            }
        });
        let _ = es.add_event_listener_with_callback(event_type, callback.as_ref().unchecked_ref());
        callback.forget();
    }

    {
        let connected_url = url.clone();
        let callback = Closure::<dyn FnMut()>::new(move || {
            log::info!("Legacy TRPG SSE connected to {}", connected_url);
        });
        es.set_onopen(Some(callback.as_ref().unchecked_ref()));
        callback.forget();
    }

    {
        let callback = Closure::<dyn FnMut()>::new(move || {
            log::warn!("Legacy TRPG SSE connection error");
        });
        es.set_onerror(Some(callback.as_ref().unchecked_ref()));
        callback.forget();
    }

    if let Ok(mut guard) = es_handle.lock() {
        *guard = Some(SendEventSource(es));
    }

    commands.insert_resource(SseReceiver {
        messages,
        polling_active: active,
        event_source: es_handle,
    });
}

/// Native no-op for setup_sse.
#[cfg(not(target_arch = "wasm32"))]
pub fn setup_sse(mut _commands: Commands) {}

/// OnExit(Trpg) system: stops polling, closes EventSource, and removes resource.
pub fn teardown_sse(mut commands: Commands, receiver: Option<Res<SseReceiver>>) {
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
        assert_eq!(mapped.len(), 3);
        assert_eq!(mapped[0].0, "turn_advance");
        assert_eq!(mapped[1].0, "turn_advance");
        assert_eq!(mapped[2].0, "dice_roll");

        let turn_payload: Value = serde_json::from_str(&mapped[1].1).expect("turn payload json");
        assert_eq!(turn_payload["turn"], 3);
        assert_eq!(turn_payload["phase"], "player_action");

        let dice_payload: Value = serde_json::from_str(&mapped[2].1).expect("dice payload json");
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
        assert_eq!(mapped.len(), 1);
        assert_eq!(mapped[0].0, "narrative");

        let payload: Value = serde_json::from_str(&mapped[0].1).expect("narrative payload json");
        assert_eq!(payload["text"], "문이 열린다");
        assert_eq!(payload["speaker"], "dm");
    }
}
