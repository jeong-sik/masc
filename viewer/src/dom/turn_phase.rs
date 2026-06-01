use bevy::prelude::*;
use wasm_bindgen::JsCast;

use crate::game::state::WorkspaceState;

/// Tracks the last-rendered turn/phase to avoid redundant DOM updates.
#[derive(Resource, Default)]
pub struct TurnPhaseCache {
    pub last_turn: u32,
    pub last_phase: String,
}

/// All phases in order, matching the data-phase attributes in index.html.
const PHASES: &[&str] = &[
    "dm_narration",
    "party_discussion",
    "action_declaration",
    "dice_resolution",
    "outcome_narration",
    "state_update",
    "transition",
];

/// Updates the turn phase bar in the DOM.
pub fn update_turn_phase_dom(workspace_state: Res<WorkspaceState>, mut cache: ResMut<TurnPhaseCache>) {
    let current_phase = workspace_state.phase.as_str().to_string();

    // Skip if nothing changed
    if cache.last_turn == workspace_state.turn && cache.last_phase == current_phase {
        return;
    }
    cache.last_turn = workspace_state.turn;
    cache.last_phase = current_phase.clone();

    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };

    // Update turn number
    if let Some(el) = document.get_element_by_id("turn-num") {
        el.set_text_content(Some(&workspace_state.turn.to_string()));
    }

    // Update phase highlights
    let current_idx = PHASES.iter().position(|&p| p == current_phase);

    let Ok(phase_els) = document.query_selector_all(".phase") else {
        return;
    };

    for i in 0..phase_els.length() {
        let Some(el) = phase_els.get(i) else { continue };
        let Some(element) = el.dyn_ref::<web_sys::Element>() else {
            continue;
        };

        let phase_name = element.get_attribute("data-phase").unwrap_or_default();
        let phase_idx = PHASES.iter().position(|&p| p == phase_name);

        let class = match (current_idx, phase_idx) {
            (Some(ci), Some(pi)) if pi < ci => "phase completed",
            (Some(ci), Some(pi)) if pi == ci => "phase active",
            _ => "phase",
        };
        element.set_class_name(class);
    }
}
