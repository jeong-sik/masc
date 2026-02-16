use std::sync::{Arc, Mutex};
use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use web_sys::{EventSource, MessageEvent};

use crate::config;
use crate::mode::ViewerMode;

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
}

/// MASC MCP SSE event types.
/// These must match the event names emitted by the MASC MCP server.
const MASC_SSE_EVENT_TYPES: &[&str] = &[
    "broadcast",
    "heartbeat",
    "agent_joined",
    "agent_left",
    "task_update",
    "endpoint",
];

/// OnEnter system for MASC modes (Monitor, Council, Social, Experiment).
/// Creates an EventSource connection to the MASC MCP SSE endpoint.
#[cfg(target_arch = "wasm32")]
pub fn setup_masc_sse(mut commands: Commands, mode: Res<State<ViewerMode>>) {
    let url = match config::sse_endpoint(mode.get()) {
        Some(url) => url,
        None => {
            log::warn!("No SSE endpoint for mode {:?}", mode.get());
            return;
        }
    };

    let messages = Arc::new(Mutex::new(Vec::new()));
    let es_handle: Arc<Mutex<Option<SendEventSource>>> = Arc::new(Mutex::new(None));

    // Attempt to create EventSource; if MASC server is not running, log and continue
    let es = match EventSource::new(&url) {
        Ok(es) => es,
        Err(e) => {
            log::warn!("Failed to create MASC EventSource at {}: {:?}", url, e);
            commands.insert_resource(MascSseReceiver {
                messages,
                event_source: es_handle,
            });
            return;
        }
    };

    // Register a listener for each MASC event type
    for &event_type in MASC_SSE_EVENT_TYPES {
        let msgs = messages.clone();
        let etype = event_type.to_string();
        let callback = Closure::<dyn FnMut(MessageEvent)>::new(move |e: MessageEvent| {
            if let Some(data) = e.data().as_string() {
                if let Ok(mut buf) = msgs.lock() {
                    buf.push((etype.clone(), data));
                }
            }
        });
        let _ = es.add_event_listener_with_callback(
            event_type,
            callback.as_ref().unchecked_ref(),
        );
        // Intentionally leak the closure — it must live for the app lifetime.
        callback.forget();
    }

    // Also listen for generic "message" events (unnamed SSE events)
    {
        let msgs = messages.clone();
        let callback = Closure::<dyn FnMut(MessageEvent)>::new(move |e: MessageEvent| {
            if let Some(data) = e.data().as_string() {
                if let Ok(mut buf) = msgs.lock() {
                    buf.push(("message".to_string(), data));
                }
            }
        });
        es.set_onmessage(Some(callback.as_ref().unchecked_ref()));
        callback.forget();
    }

    // Track connection state via onopen / onerror
    {
        let connected_url = url.clone();
        let callback = Closure::<dyn FnMut()>::new(move || {
            log::info!("MASC SSE connected to {}", connected_url);
        });
        es.set_onopen(Some(callback.as_ref().unchecked_ref()));
        callback.forget();
    }

    {
        let callback = Closure::<dyn FnMut()>::new(move || {
            log::warn!("MASC SSE connection error — will auto-reconnect");
        });
        es.set_onerror(Some(callback.as_ref().unchecked_ref()));
        callback.forget();
    }

    // Store handle so teardown can call .close()
    if let Ok(mut guard) = es_handle.lock() {
        *guard = Some(SendEventSource(es));
    }

    commands.insert_resource(MascSseReceiver {
        messages,
        event_source: es_handle,
    });

    log::info!(
        "MASC SSE client initialized for {:?}, subscribing to {} event types",
        mode.get(),
        MASC_SSE_EVENT_TYPES.len()
    );
}

/// Native no-op for setup_masc_sse.
#[cfg(not(target_arch = "wasm32"))]
pub fn setup_masc_sse(mut _commands: Commands, _mode: Res<State<ViewerMode>>) {}

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
