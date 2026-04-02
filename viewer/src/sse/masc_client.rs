use bevy::prelude::*;
use std::sync::{Arc, Mutex};

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use web_sys::{EventSource, MessageEvent};

#[cfg(target_arch = "wasm32")]
use crate::config;
use crate::mode::ViewerMode;

#[cfg(target_arch = "wasm32")]
use super::reconnect;
use super::reconnect::{ConnectionStatusBridge, SseReconnectManager};
#[cfg(target_arch = "wasm32")]
use super::reconnect::{ConnectionStatusProxy, ReconnectState};
#[cfg(target_arch = "wasm32")]
use crate::game::state::ConnectionStatus;

/// Wrapper around `EventSource` that is `Send + Sync`.
/// Safe because WASM is single-threaded — there are no real threads to race with.
#[cfg(target_arch = "wasm32")]
struct SendEventSource(EventSource);

#[cfg(target_arch = "wasm32")]
unsafe impl Send for SendEventSource {}
#[cfg(target_arch = "wasm32")]
unsafe impl Sync for SendEventSource {}

/// Shared buffer for incoming MASC SSE messages.
/// Separate from `SseReceiver` (TRPG) — they coexist independently.
///
/// The EventSource callbacks push (event_type, data) tuples,
/// and the Bevy system drains them each frame.
#[derive(Resource, Clone)]
pub struct MascSseReceiver {
    pub messages: Arc<Mutex<Vec<(String, String)>>>,
    #[cfg(target_arch = "wasm32")]
    event_source: Arc<Mutex<Option<SendEventSource>>>,
    /// Shared reconnect state for this connection.
    /// Kept alive so the Arc clones in EventSource callbacks remain valid.
    #[cfg(target_arch = "wasm32")]
    #[allow(dead_code)]
    reconnect: Arc<Mutex<ReconnectState>>,
}

/// MASC MCP SSE event types.
/// These must match the event names emitted by the MASC MCP server.
#[cfg(target_arch = "wasm32")]
const MASC_SSE_EVENT_TYPES: &[&str] = &[
    // Core events
    "broadcast",
    "heartbeat",
    "agent_joined",
    "agent_left",
    "task_update",
    "endpoint",
    // Experiment (A/B testing)
    "experiment_created",
    "experiment_assignment",
    "experiment_observation",
    "experiment_checkpoint",
    "experiment_concluded",
    // TRPG extensions
    "scene_transition",
    "quest_update",
    "world_event",
];

/// Create an EventSource for the given URL, wire up all event listeners,
/// and store it in the provided handle. Reconnection on error is handled
/// by scheduling a delayed retry via `reconnect::schedule_reconnect`.
#[cfg(target_arch = "wasm32")]
fn create_event_source(
    url: &str,
    messages: Arc<Mutex<Vec<(String, String)>>>,
    es_handle: Arc<Mutex<Option<SendEventSource>>>,
    reconnect_state: Arc<Mutex<ReconnectState>>,
    status_proxy: Arc<Mutex<ConnectionStatusProxy>>,
    mode_name: String,
) {
    let safe_url = config::redact_auth_query(url);
    let es = match EventSource::new(url) {
        Ok(es) => es,
        Err(e) => {
            log::warn!("Failed to create MASC EventSource at {}: {:?}", safe_url, e);
            attempt_reconnect(
                messages,
                es_handle,
                reconnect_state,
                status_proxy,
                mode_name,
            );
            return;
        }
    };

    // Register a listener for each MASC event type
    for &event_type in MASC_SSE_EVENT_TYPES {
        let msgs = messages.clone();
        let etype = event_type.to_string();
        let rs = reconnect_state.clone();
        let callback = Closure::<dyn FnMut(MessageEvent)>::new(move |e: MessageEvent| {
            if let Some(data) = e.data().as_string() {
                if let Ok(mut buf) = msgs.lock() {
                    buf.push((etype.clone(), data));
                }
            }
            // Track last event ID for resumption
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

    // Also listen for generic "message" events (unnamed SSE events)
    {
        let msgs = messages.clone();
        let rs = reconnect_state.clone();
        let callback = Closure::<dyn FnMut(MessageEvent)>::new(move |e: MessageEvent| {
            if let Some(data) = e.data().as_string() {
                if let Ok(mut buf) = msgs.lock() {
                    buf.push(("message".to_string(), data));
                }
            }
            let event_id = e.last_event_id();
            if !event_id.is_empty() {
                if let Ok(mut state) = rs.lock() {
                    state.record_event_id(&event_id);
                }
            }
        });
        es.set_onmessage(Some(callback.as_ref().unchecked_ref()));
        callback.forget();
    }

    // onopen: reset reconnect state, mark connected
    {
        let connected_url = safe_url.clone();
        let rs = reconnect_state.clone();
        let sp = status_proxy.clone();
        let callback = Closure::<dyn FnMut()>::new(move || {
            log::info!("MASC SSE connected to {}", connected_url);
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

    // onerror: attempt reconnection with backoff
    {
        let msgs = messages.clone();
        let esh = es_handle.clone();
        let rs = reconnect_state.clone();
        let sp = status_proxy.clone();
        let mn = mode_name.clone();
        let callback = Closure::<dyn FnMut()>::new(move || {
            log::warn!("MASC SSE connection error — scheduling reconnect");
            // Close the failed EventSource
            if let Ok(guard) = esh.lock() {
                if let Some(es) = guard.as_ref() {
                    es.0.close();
                }
            }
            attempt_reconnect(
                msgs.clone(),
                esh.clone(),
                rs.clone(),
                sp.clone(),
                mn.clone(),
            );
        });
        es.set_onerror(Some(callback.as_ref().unchecked_ref()));
        callback.forget();
    }

    // Store handle
    if let Ok(mut guard) = es_handle.lock() {
        *guard = Some(SendEventSource(es));
    }

    log::info!(
        "MASC SSE client initialized for {}, subscribing to {} event types",
        mode_name,
        MASC_SSE_EVENT_TYPES.len()
    );
}

/// Attempt a reconnection using the current ReconnectState.
/// If retries are exhausted, marks the connection as Failed.
#[cfg(target_arch = "wasm32")]
fn attempt_reconnect(
    messages: Arc<Mutex<Vec<(String, String)>>>,
    es_handle: Arc<Mutex<Option<SendEventSource>>>,
    reconnect_state: Arc<Mutex<ReconnectState>>,
    status_proxy: Arc<Mutex<ConnectionStatusProxy>>,
    mode_name: String,
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
                    "MASC SSE reconnect exhausted ({} attempts) — giving up",
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
        "MASC SSE reconnect attempt {}/{} in {}ms",
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
            // Compute the URL, attaching lastEventId if we have one
            let base_url = config::sse_endpoint_by_name(&mode_name).unwrap_or_default();
            let url = reconnect::url_with_last_event_id(&base_url, &last_event_id);
            let authed_url = config::attach_auth_query(&url);
            create_event_source(
                &authed_url,
                messages,
                es_handle,
                reconnect_state,
                status_proxy,
                mode_name,
            );
        },
    );
}

/// OnEnter system for MASC modes (Monitor, Social, Experiment).
/// Creates an EventSource connection to the MASC MCP SSE endpoint.
#[cfg(target_arch = "wasm32")]
pub fn setup_masc_sse(
    mut commands: Commands,
    mode: Res<State<ViewerMode>>,
    bridge: Res<ConnectionStatusBridge>,
    mut reconnect_mgr: ResMut<SseReconnectManager>,
) {
    let url = match config::sse_endpoint(mode.get()) {
        Some(url) => url,
        None => {
            log::warn!("No SSE endpoint for mode {:?}", mode.get());
            return;
        }
    };
    let url = config::attach_auth_query(&url);

    let messages = Arc::new(Mutex::new(Vec::new()));
    let es_handle: Arc<Mutex<Option<SendEventSource>>> = Arc::new(Mutex::new(None));

    // Reset MASC reconnect state for this new connection
    reconnect_mgr.masc = ReconnectState::default();
    let reconnect_state = Arc::new(Mutex::new(reconnect_mgr.masc.clone()));

    let mode_name = format!("{:?}", mode.get());

    create_event_source(
        &url,
        messages.clone(),
        es_handle.clone(),
        reconnect_state.clone(),
        bridge.proxy.clone(),
        mode_name,
    );

    commands.insert_resource(MascSseReceiver {
        messages,
        event_source: es_handle,
        reconnect: reconnect_state,
    });
}

/// Native no-op for setup_masc_sse.
#[cfg(not(target_arch = "wasm32"))]
pub fn setup_masc_sse(
    mut _commands: Commands,
    _mode: Res<State<ViewerMode>>,
    _bridge: Res<ConnectionStatusBridge>,
    _reconnect_mgr: ResMut<SseReconnectManager>,
) {
}

/// OnExit system: closes the MASC EventSource connection and removes the resource.
pub fn teardown_masc_sse(mut commands: Commands, receiver: Option<Res<MascSseReceiver>>) {
    if let Some(recv) = receiver {
        #[cfg(target_arch = "wasm32")]
        {
            if let Ok(guard) = recv.event_source.lock() {
                if let Some(es) = guard.as_ref() {
                    es.0.close();
                    log::info!("MASC SSE EventSource closed");
                }
            }
        }
        let _ = &recv;
    }
    commands.remove_resource::<MascSseReceiver>();
    log::info!("MascSseReceiver resource removed");
}
