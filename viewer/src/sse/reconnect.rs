//! SSE auto-reconnection with exponential backoff.
//!
//! Provides `ReconnectState` for tracking retry attempts and computing
//! jittered exponential delays, plus a `reconnect_sse` helper that
//! spawns a delayed reconnection attempt on the WASM event loop.

#![allow(dead_code)] // Full reconnection subsystem — not yet wired to runtime.

use std::sync::{Arc, Mutex};

use bevy::prelude::*;

use crate::game::state::ConnectionStatus;

/// Reconnection parameters.
const INITIAL_DELAY_MS: u32 = 1_000;
const MAX_DELAY_MS: u32 = 30_000;
const BACKOFF_FACTOR: u32 = 2;
const MAX_RETRIES: u32 = 10;
/// Jitter range: +/- 25% of the computed delay.
const JITTER_FRACTION: f64 = 0.25;

/// Tracks reconnection state for a single SSE connection.
#[derive(Debug, Clone)]
pub struct ReconnectState {
    pub attempt: u32,
    pub max_retries: u32,
    next_delay_ms: u32,
    /// Last event ID received before disconnect (for resume).
    pub last_event_id: Option<String>,
}

impl Default for ReconnectState {
    fn default() -> Self {
        Self {
            attempt: 0,
            max_retries: MAX_RETRIES,
            next_delay_ms: INITIAL_DELAY_MS,
            last_event_id: None,
        }
    }
}

impl ReconnectState {
    /// Reset state after a successful connection.
    pub fn reset(&mut self) {
        self.attempt = 0;
        self.next_delay_ms = INITIAL_DELAY_MS;
    }

    /// Returns true if we have exhausted all retry attempts.
    pub fn exhausted(&self) -> bool {
        self.attempt >= self.max_retries
    }

    /// Compute the next delay with jitter, advance attempt counter.
    /// Returns `None` if retries are exhausted.
    pub fn next_delay(&mut self) -> Option<u32> {
        if self.exhausted() {
            return None;
        }
        self.attempt += 1;
        let base = self.next_delay_ms;

        // Apply jitter: uniform random in [base * (1 - j), base * (1 + j)]
        let jitter = apply_jitter(base, JITTER_FRACTION);

        // Advance for next call (exponential)
        self.next_delay_ms = base.saturating_mul(BACKOFF_FACTOR).min(MAX_DELAY_MS);

        Some(jitter)
    }

    /// Record the last event ID from an incoming SSE message.
    pub fn record_event_id(&mut self, id: &str) {
        if !id.is_empty() {
            self.last_event_id = Some(id.to_string());
        }
    }
}

/// Bevy resource holding reconnect state for TRPG and MASC connections.
#[derive(Resource, Default)]
pub struct SseReconnectManager {
    pub trpg: ReconnectState,
    pub masc: ReconnectState,
}

/// Apply jitter to a base delay. Uses a simple pseudo-random approach
/// based on js_sys::Math::random() in WASM, or a deterministic fallback.
fn apply_jitter(base_ms: u32, fraction: f64) -> u32 {
    let random = get_random();
    let jitter_range = (base_ms as f64) * fraction;
    // random in [0, 1) -> offset in [-jitter_range, +jitter_range)
    let offset = (random * 2.0 - 1.0) * jitter_range;
    let result = (base_ms as f64 + offset).round();
    // Clamp to at least 100ms
    (result as u32).max(100)
}

#[cfg(target_arch = "wasm32")]
fn get_random() -> f64 {
    js_sys::Math::random()
}

#[cfg(not(target_arch = "wasm32"))]
fn get_random() -> f64 {
    0.5 // deterministic for tests
}

/// Schedule an SSE reconnection after `delay_ms` milliseconds.
///
/// `reconnect_fn` is called once the delay elapses. It runs on the WASM
/// microtask queue via `spawn_local`. The `connection_status` resource is
/// updated to `Reconnecting` before the delay and to `Connecting` after.
#[cfg(target_arch = "wasm32")]
pub fn schedule_reconnect(
    delay_ms: u32,
    attempt: u32,
    max_retries: u32,
    connection_status: Arc<Mutex<ConnectionStatusProxy>>,
    reconnect_fn: impl FnOnce() + 'static,
) {
    use wasm_bindgen::prelude::*;
    use wasm_bindgen::JsCast;
    use wasm_bindgen_futures::JsFuture;

    // Update status to Reconnecting
    if let Ok(mut proxy) = connection_status.lock() {
        proxy.set(ConnectionStatus::Reconnecting(attempt, max_retries));
    }

    wasm_bindgen_futures::spawn_local(async move {
        // Sleep for delay_ms
        let promise = js_sys::Promise::new(&mut |resolve, _reject| {
            if let Some(window) = web_sys::window() {
                let _ = window.set_timeout_with_callback_and_timeout_and_arguments_0(
                    resolve.unchecked_ref(),
                    delay_ms as i32,
                );
            } else {
                let _ = resolve.call0(&JsValue::NULL);
            }
        });
        let _ = JsFuture::from(promise).await;

        // Update status to Connecting
        if let Ok(mut proxy) = connection_status.lock() {
            proxy.set(ConnectionStatus::Connecting);
        }

        reconnect_fn();
    });
}

/// A thread-safe proxy for updating `ConnectionStatus` from async contexts.
///
/// Since Bevy resources can only be accessed from systems, this proxy
/// stores the desired status and the Bevy system reads it each frame.
#[derive(Debug)]
pub struct ConnectionStatusProxy {
    pending: Option<ConnectionStatus>,
}

impl ConnectionStatusProxy {
    pub fn new() -> Self {
        Self { pending: None }
    }

    pub fn set(&mut self, status: ConnectionStatus) {
        self.pending = Some(status);
    }

    pub fn take(&mut self) -> Option<ConnectionStatus> {
        self.pending.take()
    }
}

/// Bevy resource that bridges async reconnect status updates into the ECS.
#[derive(Resource)]
pub struct ConnectionStatusBridge {
    pub proxy: Arc<Mutex<ConnectionStatusProxy>>,
}

impl Default for ConnectionStatusBridge {
    fn default() -> Self {
        Self {
            proxy: Arc::new(Mutex::new(ConnectionStatusProxy::new())),
        }
    }
}

/// Bevy system: apply any pending connection status from the async proxy.
pub fn sync_connection_status(
    bridge: Option<Res<ConnectionStatusBridge>>,
    mut connection: ResMut<ConnectionStatus>,
) {
    let Some(bridge) = bridge else { return };
    let pending = {
        match bridge.proxy.lock() {
            Ok(mut proxy) => proxy.take(),
            Err(_) => None,
        }
    };
    if let Some(status) = pending {
        *connection = status;
    }
}

/// Append `lastEventId` query parameter to a URL if available.
pub fn url_with_last_event_id(base_url: &str, last_event_id: &Option<String>) -> String {
    match last_event_id {
        Some(id) if !id.is_empty() => {
            let separator = if base_url.contains('?') { "&" } else { "?" };
            format!("{}{}lastEventId={}", base_url, separator, id)
        }
        _ => base_url.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconnect_state_default_values() {
        let state = ReconnectState::default();
        assert_eq!(state.attempt, 0);
        assert_eq!(state.max_retries, 10);
        assert!(!state.exhausted());
    }

    #[test]
    fn reconnect_state_exponential_backoff() {
        let mut state = ReconnectState::default();
        // First delay should be around 1000ms (with jitter)
        let d1 = state
            .next_delay()
            .expect("next_delay should return Some on attempt 1");
        assert!((750..=1250).contains(&d1), "d1={}", d1);
        assert_eq!(state.attempt, 1);

        // Second delay should be around 2000ms
        let d2 = state
            .next_delay()
            .expect("next_delay should return Some on attempt 2");
        assert!((1500..=2500).contains(&d2), "d2={}", d2);
        assert_eq!(state.attempt, 2);

        // Third delay should be around 4000ms
        let d3 = state
            .next_delay()
            .expect("next_delay should return Some on attempt 3");
        assert!((3000..=5000).contains(&d3), "d3={}", d3);
    }

    #[test]
    fn reconnect_state_caps_at_max_delay() {
        let mut state = ReconnectState::default();
        // Exhaust delays up to the cap
        for _ in 0..8 {
            state.next_delay();
        }
        // By attempt 8, base delay should be capped at 30000ms
        let d = state
            .next_delay()
            .expect("next_delay should return Some before exhaustion");
        assert!(d <= 37500, "d={} should be <= 37500 (30000 + 25%)", d);
    }

    #[test]
    fn reconnect_state_exhaustion() {
        let mut state = ReconnectState::default();
        for _ in 0..10 {
            assert!(state.next_delay().is_some());
        }
        assert!(state.exhausted());
        assert!(state.next_delay().is_none());
    }

    #[test]
    fn reconnect_state_reset() {
        let mut state = ReconnectState::default();
        state.next_delay();
        state.next_delay();
        assert_eq!(state.attempt, 2);

        state.reset();
        assert_eq!(state.attempt, 0);
        assert!(!state.exhausted());
    }

    #[test]
    fn url_with_last_event_id_none() {
        let url = url_with_last_event_id("http://example.com/sse", &None);
        assert_eq!(url, "http://example.com/sse");
    }

    #[test]
    fn url_with_last_event_id_some() {
        let url = url_with_last_event_id("http://example.com/sse", &Some("42".to_string()));
        assert_eq!(url, "http://example.com/sse?lastEventId=42");
    }

    #[test]
    fn url_with_last_event_id_existing_params() {
        let url =
            url_with_last_event_id("http://example.com/sse?workspace=abc", &Some("99".to_string()));
        assert_eq!(url, "http://example.com/sse?workspace=abc&lastEventId=99");
    }

    #[test]
    fn url_with_last_event_id_empty_string() {
        let url = url_with_last_event_id("http://example.com/sse", &Some("".to_string()));
        assert_eq!(url, "http://example.com/sse");
    }

    #[test]
    fn record_event_id_updates() {
        let mut state = ReconnectState::default();
        assert!(state.last_event_id.is_none());
        state.record_event_id("ev-5");
        assert_eq!(state.last_event_id.as_deref(), Some("ev-5"));
        state.record_event_id("");
        assert_eq!(state.last_event_id.as_deref(), Some("ev-5")); // empty ignored
    }

    #[test]
    fn connection_status_proxy_round_trip() {
        let mut proxy = ConnectionStatusProxy::new();
        assert!(proxy.take().is_none());
        proxy.set(ConnectionStatus::Connected);
        match proxy.take() {
            Some(ConnectionStatus::Connected) => {}
            other => panic!("expected Connected, got {:?}", other),
        }
        assert!(proxy.take().is_none());
    }
}
