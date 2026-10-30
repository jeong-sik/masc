pub mod bridge;
pub mod client;
pub mod reconnect;

use bevy::prelude::*;

use crate::mode::ViewerMode;

/// TRPG JSON polling bridge. Mode admission refuses TRPG while this
/// repository has no canonical producer, so these gated systems remain inert.
/// Async connection status is synchronized into ECS separately.
pub struct TrpgPollingPlugin;

impl Plugin for TrpgPollingPlugin {
    fn build(&self, app: &mut App) {
        // ── Reconnect infrastructure ──
        app.init_resource::<reconnect::SseReconnectManager>()
            .init_resource::<reconnect::ConnectionStatusBridge>();

        // ── TRPG JSON polling (unavailable mode cannot enter) ──
        app.add_systems(OnEnter(ViewerMode::Trpg), client::setup_polling)
            .add_systems(
                Update,
                bridge::poll_sse_events.run_if(in_state(ViewerMode::Trpg)),
            )
            .add_systems(OnExit(ViewerMode::Trpg), client::teardown_polling);

        // ── Sync async connection status into ECS (runs every frame) ──
        app.add_systems(Update, reconnect::sync_connection_status);
    }
}
