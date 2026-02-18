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

#[cfg(target_arch = "wasm32")]
use crate::config;
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
#[cfg(target_arch = "wasm32")]
const MAX_ROUNDS: u32 = 50;

/// Delay between rounds (ms) — gives SSE events time to stream + user to read.
#[cfg(target_arch = "wasm32")]
const INTER_ROUND_DELAY_MS: i32 = 5000;

/// Initial delay before first round (ms) — wait for SSE + initial state.
#[cfg(target_arch = "wasm32")]
const STARTUP_DELAY_MS: i32 = 3000;

// ─── OnEnter System ────────────────────────────

/// Spawns the async round-run loop when entering TRPG mode.
pub fn start_round_loop(
    mut commands: Commands,
    progress: Res<TurnProgressState>,
) {
    let runner = RoundRunner::default();

    #[cfg(target_arch = "wasm32")]
    if !auto_round_enabled() {
        runner.running.store(false, Ordering::SeqCst);
        log::info!("RoundRunner: auto round loop disabled (manual Run Round only)");
        commands.insert_resource(runner);
        return;
    }

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

                let body = match build_round_body(&dm_keeper_snapshot) {
                    Ok(body) => body,
                    Err(reason) => {
                        log::warn!(
                            "RoundRunner: missing/invalid round plan, stopping auto loop — {}",
                            reason
                        );
                        break;
                    }
                };

                let url = format!("{}/api/v1/trpg/rounds/run", config::MASC_MCP_URL);
                match fetch_json_post(&url, &body).await {
                    Ok(resp) => {
                        log::info!(
                            "RoundRunner: round {} done — {}",
                            round_num,
                            &resp[..resp.len().min(200)]
                        );
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
                        } else if matches!(round_response_advanced(&resp), Some(false)) {
                            log::warn!(
                                "RoundRunner: round did not advance (player failure/claim mismatch). Stopping auto loop."
                            );
                            break;
                        }
                    }
                    Err(e) => {
                        let detail = e
                            .as_string()
                            .unwrap_or_else(|| format!("{:?}", e));
                        log::warn!("RoundRunner: POST failed — {}", detail);

                        // Stop on non-retriable client errors to prevent runaway loops.
                        if let Some(status) = parse_http_status(&detail) {
                            if (400..500).contains(&status) && status != 429 {
                                log::warn!(
                                    "RoundRunner: stopping due to non-retriable HTTP {}",
                                    status
                                );
                                break;
                            }
                        } else if detail.contains("404") || detail.contains("422") {
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
fn build_round_body(dm_keeper_fallback: &str) -> Result<String, String> {
    use serde_json::{json, Map, Value};

    let room_id = config::current_room_id();

    // 1) DM keeper: explicit round-run field > claimed keeper > new-game picker > ECS snapshot.
    let dm_keeper = read_dom_input("round-run-dm")
        .or_else(|| read_dom_input("claimed-keeper"))
        .or_else(|| read_dom_input("new-game-dm-select"))
        .or_else(|| {
            let fallback = dm_keeper_fallback.trim();
            if fallback.is_empty() {
                None
            } else {
                Some(fallback.to_string())
            }
        })
        .ok_or_else(|| "DM keeper가 비어 있습니다.".to_string())?;

    let phase = read_dom_input("round-run-phase").unwrap_or_else(|| "round".to_string());
    let timeout_sec = read_dom_input("round-run-timeout")
        .and_then(|raw| raw.parse::<f64>().ok())
        .filter(|value| *value > 0.0)
        .unwrap_or(90.0);
    let lang = read_dom_input("round-run-lang").unwrap_or_else(|| "ko".to_string());

    // 2) Player keeper mapping from hidden round plan (`actor=keeper,actor=keeper,...`).
    let mut player_pairs = read_dom_value("round-run-players")
        .map(|raw| parse_player_keeper_pairs(&raw))
        .unwrap_or_default();
    if player_pairs.is_empty() {
        if let (Some(actor_id), Some(keeper_name)) = (
            read_dom_input("claimed-actor-id"),
            read_dom_input("claimed-keeper"),
        ) {
            player_pairs.push((actor_id, keeper_name));
        }
    }
    if player_pairs.is_empty() {
        return Err("player keeper 매핑이 비어 있습니다.".to_string());
    }

    let mut player_keepers = Map::new();
    for (actor_id, keeper_name) in player_pairs {
        player_keepers.insert(actor_id, Value::String(keeper_name));
    }

    let body = json!({
        "room_id": room_id,
        "dm_keeper": dm_keeper,
        "player_keepers": Value::Object(player_keepers),
        "phase": phase,
        "timeout_sec": timeout_sec,
        "lang": lang,
        "require_claim": true
    });

    Ok(body.to_string())
}

/// Read a value from a DOM input element by ID.
#[cfg(target_arch = "wasm32")]
fn read_dom_value(id: &str) -> Option<String> {
    use wasm_bindgen::JsCast;

    let doc = web_sys::window()?.document()?;
    let el = doc.get_element_by_id(id)?;
    el
        .dyn_ref::<web_sys::HtmlInputElement>()
        .map(|i| i.value())
        .or_else(|| {
            el.dyn_ref::<web_sys::HtmlSelectElement>()
                .map(|s| s.value())
        })
}

#[cfg(target_arch = "wasm32")]
fn read_dom_input(id: &str) -> Option<String> {
    let value = read_dom_value(id)?;
    let trimmed = value.trim().to_string();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

#[cfg(target_arch = "wasm32")]
fn round_response_advanced(resp: &str) -> Option<bool> {
    let parsed = serde_json::from_str::<serde_json::Value>(resp).ok()?;
    parsed
        .get("summary")
        .and_then(|summary| summary.get("advanced"))
        .and_then(serde_json::Value::as_bool)
}

#[cfg(target_arch = "wasm32")]
fn parse_player_keeper_pairs(raw: &str) -> Vec<(String, String)> {
    raw.split(',')
        .filter_map(|part| {
            let pair = part.trim();
            if pair.is_empty() {
                return None;
            }
            let mut pieces = pair.splitn(2, '=');
            let actor_id = pieces.next()?.trim();
            let keeper_name = pieces.next()?.trim();
            if actor_id.is_empty() || keeper_name.is_empty() {
                None
            } else {
                Some((actor_id.to_string(), keeper_name.to_string()))
            }
        })
        .collect()
}

#[cfg(target_arch = "wasm32")]
fn parse_http_status(detail: &str) -> Option<u16> {
    let rest = detail.strip_prefix("HTTP ")?;
    let code_text = rest.split([' ', ':']).next()?.trim();
    if code_text.is_empty() {
        None
    } else {
        code_text.parse::<u16>().ok()
    }
}

#[cfg(target_arch = "wasm32")]
fn auto_round_enabled() -> bool {
    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return false;
    };
    let Some(dashboard) = document.get_element_by_id("dashboard") else {
        return false;
    };
    dashboard
        .get_attribute("data-auto-round")
        .map(|value| matches!(value.as_str(), "1" | "true" | "on"))
        .unwrap_or(false)
}

// ─── Sleep Helper ──────────────────────────────

#[cfg(target_arch = "wasm32")]
async fn sleep_ms(ms: i32) {
    let promise = js_sys::Promise::new(&mut |resolve, _| {
        web_sys::window()
            .expect("window not available")
            .set_timeout_with_callback_and_timeout_and_arguments_0(&resolve, ms)
            .expect("DOM: setTimeout failed");
    });
    wasm_bindgen_futures::JsFuture::from(promise).await.ok();
}
