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
#[cfg(target_arch = "wasm32")]
use std::cell::RefCell;
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

#[cfg(target_arch = "wasm32")]
#[derive(Clone)]
struct RoundRunnerControl {
    running: Arc<AtomicBool>,
    game_ended: Arc<AtomicBool>,
    last_result: Arc<Mutex<Option<String>>>,
    rounds_completed: Arc<Mutex<u32>>,
    dm_keeper_snapshot: String,
}

#[cfg(target_arch = "wasm32")]
thread_local! {
    static ROUND_RUNNER_CONTROL: RefCell<Option<RoundRunnerControl>> = const { RefCell::new(None) };
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

/// Retry budget when a round response is successful but does not advance turn.
#[cfg(any(target_arch = "wasm32", test))]
#[allow(dead_code)] // Used in wasm runtime path; test builds may not reference it directly.
const MAX_STALL_RETRIES: u32 = 3;

/// Base retry delay for stalled rounds (ms), doubled per retry.
#[cfg(any(target_arch = "wasm32", test))]
#[allow(dead_code)] // Used by stall_retry_delay_ms in wasm/runtime builds.
const STALL_RETRY_BASE_DELAY_MS: i32 = 2000;

/// Upper cap for stalled-round retry delay (ms).
#[cfg(any(target_arch = "wasm32", test))]
#[allow(dead_code)] // Used by stall_retry_delay_ms in wasm/runtime builds.
const STALL_RETRY_MAX_DELAY_MS: i32 = 12000;

#[cfg(any(target_arch = "wasm32", test))]
fn stall_retry_delay_ms(retry_count: u32) -> i32 {
    let exponent = retry_count.saturating_sub(1).min(6);
    let multiplied = STALL_RETRY_BASE_DELAY_MS.saturating_mul(1_i32 << exponent);
    multiplied.min(STALL_RETRY_MAX_DELAY_MS)
}

// ─── OnEnter System ────────────────────────────

/// Spawns the async round-run loop when entering TRPG mode.
pub fn start_round_loop(mut commands: Commands, progress: Res<TurnProgressState>) {
    let runner = RoundRunner::default();

    #[cfg(target_arch = "wasm32")]
    {
        let auto_enabled = auto_round_enabled();
        runner.running.store(auto_enabled, Ordering::SeqCst);
        if !auto_enabled {
            set_dom_runner_active(false);
            log::info!("RoundRunner: auto round loop disabled (manual Run Round only)");
        }

        let control = RoundRunnerControl {
            running: runner.running.clone(),
            game_ended: runner.game_ended.clone(),
            last_result: runner.last_result.clone(),
            rounds_completed: runner.rounds_completed.clone(),
            // Snapshot keeper info available at entry time.
            // The async loop will re-read from DOM on each iteration for freshness.
            dm_keeper_snapshot: progress.dm_keeper.clone(),
        };
        ROUND_RUNNER_CONTROL.with(|slot| {
            *slot.borrow_mut() = Some(control.clone());
        });
        if auto_enabled {
            set_dom_runner_active(true);
            spawn_round_loop(control);
        }
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
    #[cfg(target_arch = "wasm32")]
    {
        set_dom_runner_active(false);
        release_round_flight("auto");
    }
}

#[cfg(target_arch = "wasm32")]
pub fn set_auto_round_running(enabled: bool) {
    ROUND_RUNNER_CONTROL.with(|slot| {
        let Some(control) = slot.borrow().clone() else {
            log::warn!("RoundRunner: control handle not initialized");
            return;
        };

        if enabled {
            if control.running.swap(true, Ordering::SeqCst) {
                set_dom_runner_active(true);
                return;
            }
            control.game_ended.store(false, Ordering::SeqCst);
            set_dom_runner_active(true);
            spawn_round_loop(control);
        } else {
            control.running.store(false, Ordering::SeqCst);
            set_dom_runner_active(false);
            release_round_flight("auto");
            log::info!("RoundRunner: auto round loop stopped by UI");
        }
    });
}

#[cfg(not(target_arch = "wasm32"))]
#[allow(dead_code)]
pub fn set_auto_round_running(_enabled: bool) {}

#[cfg(target_arch = "wasm32")]
fn spawn_round_loop(control: RoundRunnerControl) {
    let running = control.running.clone();
    let game_ended = control.game_ended.clone();
    let last_result = control.last_result.clone();
    let rounds_completed = control.rounds_completed.clone();
    let dm_keeper_snapshot = control.dm_keeper_snapshot.clone();

    wasm_bindgen_futures::spawn_local(async move {
        // Wait for SSE connection + initial state fetch.
        sleep_ms(STARTUP_DELAY_MS).await;

        let mut round_num = 0u32;
        let mut stalled_retries = 0u32;

        while running.load(Ordering::SeqCst)
            && !game_ended.load(Ordering::SeqCst)
            && round_num < MAX_ROUNDS
        {
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
            if !try_acquire_round_flight("auto") {
                log::info!("RoundRunner: round flight locked by another request; waiting");
                sleep_ms(750).await;
                continue;
            }
            round_num += 1;
            log::info!("RoundRunner: triggering round {}", round_num);

            let url = format!("{}/api/v1/trpg/rounds/run", config::MASC_MCP_URL);
            let post_result = fetch_json_post(&url, &body).await;
            release_round_flight("auto");
            match post_result {
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
                    if resp.contains("\"status\":\"ended\"")
                        || resp.contains("\"status\":\"completed\"")
                        || resp.contains("\"game_over\":true")
                    {
                        game_ended.store(true, Ordering::SeqCst);
                        log::info!("RoundRunner: game ended signal in response");
                    } else if matches!(round_response_advanced(&resp), Some(false)) {
                        stalled_retries = stalled_retries.saturating_add(1);
                        if stalled_retries > MAX_STALL_RETRIES {
                            log::warn!(
                                "RoundRunner: round still stalled after {} retries. Stopping auto loop.",
                                MAX_STALL_RETRIES
                            );
                            break;
                        }
                        let delay_ms = stall_retry_delay_ms(stalled_retries);
                        log::warn!(
                            "RoundRunner: round did not advance (player failure/claim mismatch). Retry {}/{} in {}ms.",
                            stalled_retries,
                            MAX_STALL_RETRIES,
                            delay_ms
                        );
                        sleep_ms(delay_ms).await;
                        continue;
                    } else {
                        stalled_retries = 0;
                    }
                }
                Err(e) => {
                    let detail = e.as_string().unwrap_or_else(|| format!("{:?}", e));
                    log::warn!("RoundRunner: POST failed — {}", detail);

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

            sleep_ms(INTER_ROUND_DELAY_MS).await;
        }

        running.store(false, Ordering::SeqCst);
        set_dom_runner_active(false);
        log::info!(
            "RoundRunner: loop finished (rounds={}, ended={})",
            round_num,
            game_ended.load(Ordering::SeqCst)
        );
    });
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
    el.dyn_ref::<web_sys::HtmlInputElement>()
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

#[cfg(target_arch = "wasm32")]
fn set_dom_runner_active(active: bool) {
    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(dashboard) = document.get_element_by_id("dashboard") else {
        return;
    };
    let _ = dashboard.set_attribute("data-round-runner-active", if active { "1" } else { "0" });
}

#[cfg(target_arch = "wasm32")]
fn try_acquire_round_flight(owner: &str) -> bool {
    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return true;
    };
    let Some(dashboard) = document.get_element_by_id("dashboard") else {
        return true;
    };
    let existing = dashboard
        .get_attribute("data-round-flight-owner")
        .unwrap_or_default()
        .trim()
        .to_string();
    if existing.is_empty() {
        let _ = dashboard.set_attribute("data-round-flight-owner", owner);
        return true;
    }
    false
}

#[cfg(target_arch = "wasm32")]
fn release_round_flight(owner: &str) {
    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(dashboard) = document.get_element_by_id("dashboard") else {
        return;
    };
    let existing = dashboard
        .get_attribute("data-round-flight-owner")
        .unwrap_or_default()
        .trim()
        .to_string();
    if existing == owner {
        let _ = dashboard.remove_attribute("data-round-flight-owner");
    }
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

#[cfg(test)]
mod tests {
    use super::stall_retry_delay_ms;

    #[test]
    fn stall_retry_delay_scales_and_caps() {
        assert_eq!(stall_retry_delay_ms(1), 2000);
        assert_eq!(stall_retry_delay_ms(2), 4000);
        assert_eq!(stall_retry_delay_ms(3), 8000);
        assert_eq!(stall_retry_delay_ms(4), 12000);
        assert_eq!(stall_retry_delay_ms(8), 12000);
    }

    #[test]
    fn stall_retry_delay_handles_zero_retry_input() {
        assert_eq!(stall_retry_delay_ms(0), 2000);
    }
}
