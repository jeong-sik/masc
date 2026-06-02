pub mod bridge;
pub mod client;
pub mod masc_bridge;
pub mod masc_client;
pub mod reconnect;
pub mod social_board;

use bevy::prelude::*;

use crate::mode::ViewerMode;

/// Plugin that establishes the SSE connection to the TRPG Engine
/// and bridges SSE events into the Bevy event system.
///
/// Also manages MASC MCP SSE connections for Monitor, Social,
/// and Experiment modes — rendering events as text in DOM panels.
///
/// Social mode additionally runs a Board HTTP poller (no board SSE events
/// exist on the server, so it uses 30s polling via social_board module).
///
/// TRPG systems are gated on `ViewerMode::Trpg`. MASC systems are gated
/// on their respective modes. Each mode has its own OnEnter/OnExit lifecycle.
///
/// SSE connections include auto-reconnect with exponential backoff
/// (reconnect module). Connection status is bridged from async contexts
/// into the Bevy ECS each frame via `ConnectionStatusBridge`.
pub struct SsePlugin;

impl Plugin for SsePlugin {
    fn build(&self, app: &mut App) {
        // ── Reconnect infrastructure ──
        app.init_resource::<reconnect::SseReconnectManager>()
            .init_resource::<reconnect::ConnectionStatusBridge>();

        // ── TRPG SSE ──
        app.add_systems(OnEnter(ViewerMode::Trpg), client::setup_sse)
            .add_systems(
                Update,
                bridge::poll_sse_events.run_if(in_state(ViewerMode::Trpg)),
            )
            .add_systems(OnExit(ViewerMode::Trpg), client::teardown_sse);

        // ── MASC SSE (shared event log resource) ──
        app.init_resource::<masc_bridge::MascEventLog>();

        // ── MASC modes: Monitor, Social, Experiment ──
        let masc_modes = [ViewerMode::Monitor, ViewerMode::Social, ViewerMode::Experiment];
        for mode in masc_modes {
            app.add_systems(OnEnter(mode), masc_client::setup_masc_sse)
                .add_systems(Update, masc_bridge::poll_masc_events.run_if(in_state(mode)))
                .add_systems(OnExit(mode), masc_client::teardown_masc_sse);
        }

        // ── Social Board HTTP poller (supplements SSE with Board posts) ──
        app.add_systems(
            OnEnter(ViewerMode::Social),
            social_board::fetch_board_on_enter,
        )
        .add_systems(
            Update,
            (
                social_board::render_board_posts,
                social_board::board_refresh_tick,
            )
                .run_if(in_state(ViewerMode::Social)),
        )
        .add_systems(OnExit(ViewerMode::Social), social_board::cleanup_board);

        // ── Sync async connection status into ECS (runs every frame) ──
        app.add_systems(Update, reconnect::sync_connection_status);
    }
}
