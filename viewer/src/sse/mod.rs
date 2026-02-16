pub mod bridge;
pub mod client;
pub mod masc_bridge;
pub mod masc_client;

use bevy::prelude::*;

use crate::mode::ViewerMode;

/// Plugin that establishes the SSE connection to the TRPG Engine
/// and bridges SSE events into the Bevy event system.
///
/// Also manages MASC MCP SSE connections for Monitor, Council,
/// Social, and Experiment modes — rendering events as text in DOM panels.
///
/// TRPG systems are gated on `ViewerMode::Trpg`. MASC systems are gated
/// on their respective modes. Each mode has its own OnEnter/OnExit lifecycle.
pub struct SsePlugin;

impl Plugin for SsePlugin {
    fn build(&self, app: &mut App) {
        // ── TRPG SSE ──
        app.add_systems(OnEnter(ViewerMode::Trpg), client::setup_sse)
            .add_systems(
                Update,
                bridge::poll_sse_events.run_if(in_state(ViewerMode::Trpg)),
            )
            .add_systems(OnExit(ViewerMode::Trpg), client::teardown_sse);

        // ── MASC SSE (shared event log resource) ──
        app.init_resource::<masc_bridge::MascEventLog>();

        // ── MASC modes: Monitor, Council, Social, Experiment ──
        let masc_modes = [
            ViewerMode::Monitor,
            ViewerMode::Council,
            ViewerMode::Social,
            ViewerMode::Experiment,
        ];
        for mode in masc_modes {
            app.add_systems(OnEnter(mode), masc_client::setup_masc_sse)
                .add_systems(
                    Update,
                    masc_bridge::poll_masc_events.run_if(in_state(mode)),
                )
                .add_systems(OnExit(mode), masc_client::teardown_masc_sse);
        }
    }
}
