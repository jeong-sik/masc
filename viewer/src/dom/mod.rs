pub mod character_panel;
pub mod connection;
pub mod dice_log;
pub mod narrative;
pub mod turn_phase;

use bevy::prelude::*;

use crate::mode::ViewerMode;

/// Plugin that bridges Bevy game state changes to HTML DOM updates.
/// Text-heavy panels are rendered via DOM for scrolling, rich formatting, and CSS.
///
/// Caches are registered unconditionally. DOM update systems are gated
/// on `ViewerMode::Trpg` — other modes will register their own DOM systems.
pub struct DomBridgePlugin;

impl Plugin for DomBridgePlugin {
    fn build(&self, app: &mut App) {
        app
            // DOM caches for change detection (inert when unused)
            .init_resource::<character_panel::CharacterPanelCache>()
            .init_resource::<turn_phase::TurnPhaseCache>()
            .init_resource::<connection::ConnectionStatusCache>()
            // TRPG-specific DOM update systems
            .add_systems(Update, (
                narrative::update_narrative_dom,
                dice_log::update_dice_log_dom,
                character_panel::update_character_panel_dom,
                turn_phase::update_turn_phase_dom,
                connection::update_connection_dom,
            ).run_if(in_state(ViewerMode::Trpg)));
    }
}
