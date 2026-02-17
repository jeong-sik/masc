//! Round Runner — auto-triggers TRPG game rounds via `POST /api/v1/trpg/rounds/run`.
//!
//! On TRPG entry the runner waits for initial state, then repeatedly POSTs to
//! the rounds/run endpoint.  SSE polling picks up the resulting events.
//! Stops when the room status reaches "ended" / "completed" or the safety cap
//! is hit.

use bevy::prelude::*;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};

use crate::game::state::TurnProgressState;

// ─── Resource ──────────────────────────────────

/// Shared state between the Bevy ECS world and the async WASM loop.
#[allow(dead_code)] // Fields read by wasm32 async loop, not visible to native cargo check.
#[derive(Resource)]
pub struct RoundRunner {
    /// Whether an auto-run loop is currently active.
    pub running: Arc<AtomicBool>,
    /// Signal to stop the loop from any Bevy system.
    pub game_ended: Arc<AtomicBool>,
    /// Most recent round-run response (for debug display).
    pub last_result: Arc<Mutex<Option<String>>>,
    /// How many rounds have been executed so far.
    pub rounds_completed: Arc<Mutex<u32>>,
}

impl Default for RoundRunner {
    fn default() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            game_ended: Arc::new(AtomicBool::new(false)),
            last_result: Arc::new(Mutex::new(None)),
            rounds_completed: Arc::new(Mutex::new(0)),
        }
    }
}

/// Safety cap — prevent infinite runaway.
#[allow(dead_code)]
const MAX_ROUNDS: u32 = 50;

/// Delay between rounds (ms) — gives SSE events time to stream + user to read.
#[allow(dead_code)]
const INTER_ROUND_DELAY_MS: i32 = 5000;

/// Initial delay before first round (ms) — wait for SSE + initial state.
#[allow(dead_code)]
const STARTUP_DELAY_MS: i32 = 3000;

// ─── OnEnter System ────────────────────────────

/// Spawns the async round-run loop when entering TRPG mode.
pub fn start_round_loop(
    mut commands: Commands,
    progress: Res<TurnProgressState>,
) {
    let runner = RoundRunner::default();
    runner.running.store(true, Ordering::SeqCst);

    #[cfg(target_arch = "wasm32")]
    {
        let running = runner.running.clone();
        let game_ended = runner.game_ended.clone();
        let last_result = runner.last_result.clone();
        let rounds_completed = runner.rounds_completed.clone();

        // Snapshot keeper info available at entry time.
        // The async loop will re-read from DOM on each iteration for freshness.
        let dm_keeper_snapshot = progress.dm_keeper.clone();

        wasm_bindgen_futures::spawn_local(async move {
            // Wait for SSE connection + initial state fetch.
            sleep_ms(STARTUP_DELAY_MS).await;

            let mut round_num = 0u32;

            while running.load(Ordering::SeqCst)
                && !game_ended.load(Ordering::SeqCst)
                && round_num < MAX_ROUNDS
            {
                round_num += 1;
                log::info!("RoundRunner: triggering round {}", round_num);

                let body = build_round_body(&dm_keeper_snapshot);

                let url = format!("{}/api/v1/trpg/rounds/run", config::MASC_MCP_URL);
                match fetch_json_post(&url, &body).await {
                    Ok(resp) => {
                        log::info!("RoundRunner: round {} done — {}", round_num, &resp[..resp.len().min(200)]);
                        if let Ok(mut guard) = last_result.lock() {
                            *guard = Some(resp.clone());
                        }
                        if let Ok(mut guard) = rounds_completed.lock() {
                            *guard = round_num;
                        }
                        // Detect game-ended signals in response JSON.
                        if resp.contains("\"status\":\"ended\"")
                            || resp.contains("\"status\":\"completed\"")
                            || resp.contains("\"game_over\":true")
                        {
                            game_ended.store(true, Ordering::SeqCst);
                            log::info!("RoundRunner: game ended signal in response");
                        }
                    }
                    Err(e) => {
                        let detail = e
                            .as_string()
                            .unwrap_or_else(|| format!("{:?}", e));
                        log::warn!("RoundRunner: POST failed — {}", detail);

                        // If the room doesn't exist or the server returns a fatal error,
                        // don't spin endlessly.
                        if detail.contains("404") || detail.contains("422") {
                            log::warn!("RoundRunner: stopping due to fatal HTTP error");
                            break;
                        }
                    }
                }

                // Pause between rounds for events to stream back via SSE.
                sleep_ms(INTER_ROUND_DELAY_MS).await;
            }

            running.store(false, Ordering::SeqCst);
            log::info!(
                "RoundRunner: loop finished (rounds={}, ended={})",
                round_num,
                game_ended.load(Ordering::SeqCst)
            );
        });
    }

    let _ = &progress; // suppress unused on native
    commands.insert_resource(runner);
}

// ─── OnExit System ─────────────────────────────

/// Signals the async loop to stop when leaving TRPG mode.
pub fn stop_round_loop(runner: Option<Res<RoundRunner>>) {
    if let Some(runner) = runner {
        runner.running.store(false, Ordering::SeqCst);
        log::info!("RoundRunner: stop signalled");
    }
}

// ─── HTTP POST ─────────────────────────────────

/// POST JSON to a URL and return the response body text.
#[cfg(target_arch = "wasm32")]
async fn fetch_json_post(url: &str, body: &str) -> Result<String, wasm_bindgen::JsValue> {
    use wasm_bindgen::JsCast;
    use wasm_bindgen::JsValue;
    use wasm_bindgen_futures::JsFuture;

    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_mode(web_sys::RequestMode::Cors);
    opts.set_body(&JsValue::from_str(body));

    let request = web_sys::Request::new_with_str_and_init(url, &opts)?;
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

    let text = JsFuture::from(resp.text()?)
        .await
        .ok()
        .and_then(|v| v.as_string())
        .unwrap_or_default();
    Ok(text)
}

// ─── Body Builder ──────────────────────────────

/// Build the JSON body for `POST /api/v1/trpg/rounds/run`.
///
/// Reads keeper configuration from DOM inputs (fresh each round) with a
/// fallback to the ECS snapshot taken at session start.
#[cfg(target_arch = "wasm32")]
fn build_round_body(dm_keeper_fallback: &str) -> String {
    use serde_json::json;

    let room_id = config::current_room_id();

    // 1. DM keeper — prefer DOM input, fallback to ECS snapshot.
    let dm_keeper = read_dom_input("claimed-keeper")
        .or_else(|| read_dom_input("new-game-dm-select"))
        .unwrap_or_else(|| {
            if dm_keeper_fallback.is_empty() {
                "auto".to_string()
            } else {
                dm_keeper_fallback.to_string()
            }
        });

    // 2. Player keepers — build { actor_id: keeper_name } mapping.
    //    If we can read selected players from DOM, use them.
    //    Otherwise, send an empty object and let the backend use defaults.
    let player_keepers = build_player_keepers_from_dom();

    let body = json!({
        "room_id": room_id,
        "dm_keeper": dm_keeper,
        "player_keepers": player_keepers,
        "phase": "round",
        "timeout_sec": 90,
        "lang": "ko"
    });

    body.to_string()
}

/// Read a value from a DOM input element by ID.
#[cfg(target_arch = "wasm32")]
fn read_dom_input(id: &str) -> Option<String> {
    use wasm_bindgen::JsCast;

    let doc = web_sys::window()?.document()?;
    let el = doc.get_element_by_id(id)?;
    let value = el
        .dyn_ref::<web_sys::HtmlInputElement>()
        .map(|i| i.value())
        .or_else(|| {
            el.dyn_ref::<web_sys::HtmlSelectElement>()
                .map(|s| s.value())
        })?;
    let trimmed = value.trim().to_string();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

/// Build player_keepers mapping from DOM multi-select options.
/// Returns a serde_json::Value (object or empty object).
#[cfg(target_arch = "wasm32")]
fn build_player_keepers_from_dom() -> serde_json::Value {
    use serde_json::{json, Map, Value};
    use wasm_bindgen::JsCast;

    let mut map = Map::new();

    let doc = match web_sys::window().and_then(|w| w.document()) {
        Some(d) => d,
        None => return json!({}),
    };

    // Try to read selected player options from the multi-select.
    if let Some(el) = doc.get_element_by_id("new-game-player-select") {
        if let Some(select) = el.dyn_ref::<web_sys::HtmlSelectElement>() {
            let options = select.options();
            for i in 0..options.length() {
                if let Some(opt) = options.item(i) {
                    if let Some(opt) = opt.dyn_ref::<web_sys::HtmlOptionElement>() {
                        if opt.selected() {
                            let actor_id = opt.value();
                            if !actor_id.trim().is_empty() {
                                // Use "auto" as keeper name — backend resolves the actual keeper.
                                map.insert(actor_id, Value::String("auto".to_string()));
                            }
                        }
                    }
                }
            }
        }
    }

    Value::Object(map)
}

// ─── Sleep Helper ──────────────────────────────

#[cfg(target_arch = "wasm32")]
async fn sleep_ms(ms: i32) {
    let promise = js_sys::Promise::new(&mut |resolve, _| {
        web_sys::window()
            .unwrap()
            .set_timeout_with_callback_and_timeout_and_arguments_0(&resolve, ms)
            .unwrap();
    });
    wasm_bindgen_futures::JsFuture::from(promise).await.ok();
}
