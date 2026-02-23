pub mod action_panel;
pub mod actor_join;
pub mod actor_lifecycle;
pub mod character_panel;
pub mod choice_panel;
pub mod connection;
pub mod dice_log;
pub mod dm_voice;
pub mod endgame;
pub mod escape;
pub mod gameplay_events;
pub mod map_canvas;
pub mod narrative;
pub mod overlay;
pub mod playability_proof;
pub mod session_events;
pub mod session_history;
pub mod turn_controls;
pub mod turn_phase;
pub mod turn_runtime;
pub mod panel_visibility;

use bevy::prelude::*;

use crate::mode::ViewerMode;
#[cfg(target_arch = "wasm32")]
use crate::dom::panel_visibility::set_panel_visibility;
#[cfg(target_arch = "wasm32")]
use crate::dom::character_panel::{render_actor_inspector_empty, DEFAULT_ACTOR_INSPECTOR_EMPTY_MESSAGE};

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
            .init_resource::<session_history::SessionHistoryCache>()
            .init_resource::<turn_phase::TurnPhaseCache>()
            .init_resource::<turn_runtime::TurnRuntimeCache>()
            .init_resource::<connection::ConnectionStatusCache>()
            .init_resource::<map_canvas::CanvasMapCache>()
            .init_resource::<overlay::OverlayCache>()
            .init_resource::<endgame::EndgameState>()
            .init_resource::<crate::game::playability_contract::PlayabilityCounters>()
            .init_resource::<crate::game::playability_contract::PlayabilityThresholds>()
            .add_systems(OnEnter(ViewerMode::Trpg), reset_trpg_dom_state)
            // TRPG-specific DOM update systems
            .add_systems(
                Update,
                (
                    narrative::update_narrative_dom,
                    dice_log::update_dice_log_dom,
                    session_history::update_session_history_dom,
                    character_panel::update_character_panel_dom,
                    choice_panel::update_choice_dom,
                    gameplay_events::update_gameplay_events_dom,
                    turn_phase::update_turn_phase_dom,
                    turn_runtime::update_turn_runtime_dom,
                    connection::update_connection_dom,
                    map_canvas::update_canvas_map_dom,
                    actor_join::sync_join_panel_interaction_state,
                    action_panel::sync_action_panel_interaction_state,
                    turn_controls::sync_turn_controls_visibility,
                    overlay::update_overlay_dom,
                    actor_lifecycle::update_actor_lifecycle_dom,
                    session_events::update_session_events_dom,
                    playability_proof::update_playability_proof_dom,
                )
                    .run_if(in_state(ViewerMode::Trpg)),
            )
            .add_systems(
                Update,
                dm_voice::sync_dm_voice_controls.run_if(in_state(ViewerMode::Trpg)),
            )
            // Action panel lifecycle: bind listeners on enter, unbind on exit
            .add_systems(
                OnEnter(ViewerMode::Trpg),
                (
                    action_panel::bind_action_panel,
                    action_panel::sync_action_panel_interaction_state,
                    actor_join::bind_actor_join,
                    turn_controls::bind_turn_controls,
                    dm_voice::bind_dm_voice_controls,
                ),
            )
            .add_systems(
                OnExit(ViewerMode::Trpg),
                (
                    action_panel::unbind_action_panel,
                    actor_join::unbind_actor_join,
                    turn_controls::unbind_turn_controls,
                    dm_voice::unbind_dm_voice_controls,
                ),
            );
    }
}

fn reset_trpg_dom_state(
    mut character_cache: ResMut<character_panel::CharacterPanelCache>,
    mut turn_cache: ResMut<turn_phase::TurnPhaseCache>,
    mut runtime_cache: ResMut<turn_runtime::TurnRuntimeCache>,
    mut connection_cache: ResMut<connection::ConnectionStatusCache>,
    mut map_canvas_cache: ResMut<map_canvas::CanvasMapCache>,
    mut overlay_cache: ResMut<overlay::OverlayCache>,
    mut endgame_state: ResMut<endgame::EndgameState>,
) {
    character_cache.last_snapshot.clear();
    character_cache.last_full.clear();
    character_cache.last_progress_signature.clear();
    turn_cache.last_turn = 0;
    turn_cache.last_phase.clear();
    runtime_cache.last_snapshot.clear();
    connection_cache.last_status.clear();
    *map_canvas_cache = map_canvas::CanvasMapCache::default();
    *overlay_cache = overlay::OverlayCache::default();
    endgame_state.triggered = false;

    #[cfg(target_arch = "wasm32")]
    {
        use wasm_bindgen::JsCast;

        let Some(document) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        if let Some(el) = document.get_element_by_id("narrative-log") {
            el.set_inner_html("");
        }
        if let Some(el) = document.get_element_by_id("dice-log") {
            el.set_inner_html("");
        }
        if let Some(el) = document.get_element_by_id("session-history") {
            el.set_inner_html("");
        }
        if let Some(el) = document.get_element_by_id("character-panel") {
            el.set_inner_html("");
        }
        if let Some(el) = document.get_element_by_id("dashboard") {
            let _ = el.remove_attribute("data-selected-actor");
        }
        render_actor_inspector_empty(&document, DEFAULT_ACTOR_INSPECTOR_EMPTY_MESSAGE);
        if let Some(el) = document.get_element_by_id("turn-num") {
            el.set_text_content(Some("1"));
        }
        if let Some(el) = document.get_element_by_id("turn-runtime") {
            el.set_inner_html("");
        }
        for target_id in ["bevy-canvas", "primary-zone"] {
            if let Some(target) = document
                .get_element_by_id(target_id)
                .and_then(|el| el.dyn_into::<web_sys::HtmlElement>().ok())
            {
                let style = target.style();
                let _ = style.set_property("background-image", "url('/assets/maps/area_a.jpg')");
                let _ = style.set_property("background-size", "cover");
                let _ = style.set_property("background-position", "center");
                let _ = style.set_property("background-repeat", "no-repeat");
                let _ = style.set_property("background-color", "#05070f");
            }
        }
        if let Some(el) = document.get_element_by_id("weather-indicator") {
            el.set_text_content(None);
        }
        if let Some(el) = document.get_element_by_id("weather-icon") {
            let _ = el.remove_attribute("src");
            let _ = el.set_attribute("alt", "");
            let _ = el.set_attribute("data-empty", "1");
        }
        if let Some(el) = document.get_element_by_id("mood-indicator") {
            el.set_text_content(None);
        }
        if let Some(el) = document.get_element_by_id("mood-icon") {
            let _ = el.remove_attribute("src");
            let _ = el.set_attribute("alt", "");
            let _ = el.set_attribute("data-empty", "1");
        }
        if let Some(el) = document.get_element_by_id("choice-overlay") {
            el.set_inner_html("");
            let _ = el.set_attribute("style", "display:none");
        }
        if let Some(el) = document.get_element_by_id("combat-overlay") {
            el.set_inner_html("");
            let _ = el.set_attribute("style", "display:none");
        }
        if let Some(el) = document.get_element_by_id("event-beacon") {
            el.set_inner_html("");
            el.set_class_name("event-beacon");
        }
        set_panel_visibility(&document, "action-panel", false);
        set_panel_visibility(&document, "join-panel", true);

        // Tab reset: activate "방" tab on TRPG entry
        for tab_id in ["tab-panel-room", "tab-panel-game", "tab-panel-settings"] {
            if let Some(el) = document.get_element_by_id(tab_id) {
                if tab_id == "tab-panel-room" {
                    el.set_class_name("tab-panel active");
                } else {
                    el.set_class_name("tab-panel");
                }
            }
        }
        if let Some(bar) = document.get_element_by_id("control-tab-bar") {
            if let Ok(buttons) = bar.query_selector_all(".tab-btn") {
                for i in 0..buttons.length() {
                    if let Some(node) = buttons.item(i) {
                        if let Ok(btn) = node.dyn_into::<web_sys::Element>() {
                            let is_room = btn.get_attribute("data-tab")
                                .map_or(false, |v| v == "room");
                            if is_room {
                                let _ = btn.class_list().add_1("active");
                            } else {
                                let _ = btn.class_list().remove_1("active");
                            }
                        }
                    }
                }
            }
        }
        // Collapse ops-hud on entry
        if let Some(hud) = document.get_element_by_id("ops-hud") {
            let _ = hud.class_list().add_1("collapsed");
        }
    }
}
