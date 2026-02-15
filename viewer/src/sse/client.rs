use std::sync::{Arc, Mutex};
use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use web_sys::{EventSource, MessageEvent};

use crate::config;

/// Wrapper around `EventSource` that is `Send + Sync`.
/// Safe because WASM is single-threaded — there are no real threads to race with.
#[cfg(target_arch = "wasm32")]
struct SendEventSource(EventSource);

#[cfg(target_arch = "wasm32")]
unsafe impl Send for SendEventSource {}
#[cfg(target_arch = "wasm32")]
unsafe impl Sync for SendEventSource {}

/// Shared buffer for incoming SSE messages.
/// The EventSource callbacks push (event_type, data) tuples,
/// and the Bevy system drains them each frame.
///
/// Also holds the EventSource handle so we can `.close()` it on mode exit.
#[derive(Resource, Clone)]
pub struct SseReceiver {
    pub messages: Arc<Mutex<Vec<(String, String)>>>,
    #[cfg(target_arch = "wasm32")]
    event_source: Arc<Mutex<Option<SendEventSource>>>,
}

/// List of SSE event types the viewer subscribes to.
/// These must match the event names emitted by the TRPG Engine.
const SSE_EVENT_TYPES: &[&str] = &[
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

/// Startup system that creates the EventSource connection and registers listeners.
#[cfg(target_arch = "wasm32")]
pub fn setup_sse(mut commands: Commands) {
    let url = config::trpg_room_url("/stream");
    let messages = Arc::new(Mutex::new(Vec::new()));
    let es_handle: Arc<Mutex<Option<SendEventSource>>> = Arc::new(Mutex::new(None));

    // Attempt to create EventSource; if engine is not running, log and continue
    let es = match EventSource::new(&url) {
        Ok(es) => es,
        Err(e) => {
            log::warn!("Failed to create EventSource at {}: {:?}", url, e);
            commands.insert_resource(SseReceiver {
                messages,
                event_source: es_handle,
            });
            return;
        }
    };

    // Register a listener for each event type
    for &event_type in SSE_EVENT_TYPES {
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
        // EventSource holds a reference via the JS callback.
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
        let callback = Closure::<dyn FnMut()>::new(move || {
            log::info!("SSE connected to {}", config::trpg_room_url("/stream"));
        });
        es.set_onopen(Some(callback.as_ref().unchecked_ref()));
        callback.forget();
    }

    {
        let callback = Closure::<dyn FnMut()>::new(move || {
            log::warn!("SSE connection error — will auto-reconnect");
        });
        es.set_onerror(Some(callback.as_ref().unchecked_ref()));
        callback.forget();
    }

    // Store handle so teardown_sse can call .close()
    if let Ok(mut guard) = es_handle.lock() {
        *guard = Some(SendEventSource(es));
    }

    commands.insert_resource(SseReceiver {
        messages,
        event_source: es_handle,
    });

    log::info!("SSE client initialized, subscribing to {} event types", SSE_EVENT_TYPES.len());
}

/// Native no-op for setup_sse.
#[cfg(not(target_arch = "wasm32"))]
pub fn setup_sse(mut _commands: Commands) {}

/// OnExit(Trpg) system: closes the EventSource connection and removes the resource.
pub fn teardown_sse(mut commands: Commands, receiver: Option<Res<SseReceiver>>) {
    if let Some(recv) = receiver {
        #[cfg(target_arch = "wasm32")]
        {
            if let Ok(guard) = recv.event_source.lock() {
                if let Some(es) = guard.as_ref() {
                    es.0.close();
                    log::info!("SSE EventSource closed");
                }
            }
        }
        let _ = &recv;
    }
    commands.remove_resource::<SseReceiver>();
    log::info!("SseReceiver resource removed");
}
