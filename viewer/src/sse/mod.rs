pub mod bridge;
pub mod client;

use bevy::prelude::*;

use crate::mode::ViewerMode;

/// Plugin that establishes the SSE connection to the TRPG Engine
/// and bridges SSE events into the Bevy event system.
///
/// All systems are gated on `ViewerMode::Trpg` — the SSE connection
/// is created when entering TRPG mode and events are only polled while active.
pub struct SsePlugin;

impl Plugin for SsePlugin {
    fn build(&self, app: &mut App) {
        app
            .add_systems(OnEnter(ViewerMode::Trpg), client::setup_sse)
            .add_systems(Update, bridge::poll_sse_events.run_if(in_state(ViewerMode::Trpg)));
        // TODO: OnExit(Trpg) — close EventSource, clean up SseReceiver
    }
}
