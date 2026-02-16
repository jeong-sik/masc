pub mod action_panel;
pub mod character_panel;
pub mod connection;
pub mod dice_log;
pub mod narrative;
pub mod turn_runtime;
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
            .init_resource::<turn_runtime::TurnRuntimeCache>()
            .init_resource::<connection::ConnectionStatusCache>()
            .add_systems(OnEnter(ViewerMode::Trpg), reset_trpg_dom_state)
            // TRPG-specific DOM update systems
            .add_systems(Update, (
                narrative::update_narrative_dom,
                dice_log::update_dice_log_dom,
                character_panel::update_character_panel_dom,
                turn_phase::update_turn_phase_dom,
                turn_runtime::update_turn_runtime_dom,
                connection::update_connection_dom,
                action_panel::sync_action_panel_visibility,
            ).run_if(in_state(ViewerMode::Trpg)))
            // Action panel lifecycle: bind listeners on enter, unbind on exit
            .add_systems(OnEnter(ViewerMode::Trpg), action_panel::bind_action_panel)
            .add_systems(OnExit(ViewerMode::Trpg), action_panel::unbind_action_panel);
    }
}

fn reset_trpg_dom_state(
    mut character_cache: ResMut<character_panel::CharacterPanelCache>,
    mut turn_cache: ResMut<turn_phase::TurnPhaseCache>,
    mut runtime_cache: ResMut<turn_runtime::TurnRuntimeCache>,
    mut connection_cache: ResMut<connection::ConnectionStatusCache>,
) {
    character_cache.last_snapshot.clear();
    turn_cache.last_turn = 0;
    turn_cache.last_phase.clear();
    runtime_cache.last_snapshot.clear();
    connection_cache.last_status.clear();

    #[cfg(target_arch = "wasm32")]
    {
        let Some(document) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        if let Some(el) = document.get_element_by_id("narrative-log") {
            el.set_inner_html("");
        }
        if let Some(el) = document.get_element_by_id("dice-log") {
            el.set_inner_html("");
        }
        if let Some(el) = document.get_element_by_id("character-panel") {
            el.set_inner_html("");
        }
        if let Some(el) = document.get_element_by_id("turn-num") {
            el.set_text_content(Some("1"));
        }
        if let Some(el) = document.get_element_by_id("turn-runtime") {
            el.set_inner_html("");
        }
    }
}
