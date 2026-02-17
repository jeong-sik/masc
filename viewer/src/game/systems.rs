use bevy::prelude::*;

use super::components::*;
use super::events::*;
use super::state::*;

fn rebuild_actor_order(progress: &mut TurnProgressState) {
    progress.actor_order.clear();
    progress.actor_order.push("dm".to_string());
    for actor_id in &progress.player_order {
        if actor_id != "dm" && !progress.actor_order.iter().any(|id| id == actor_id) {
            progress.actor_order.push(actor_id.clone());
        }
    }
}

fn mark_current_and_next(progress: &mut TurnProgressState, actor_index: usize) {
    progress.current_actor = progress
        .actor_order
        .get(actor_index)
        .cloned()
        .unwrap_or_default();
    progress.next_actor = progress
        .actor_order
        .get(actor_index.saturating_add(1))
        .cloned()
        .unwrap_or_default();

    if !progress.current_actor.is_empty() {
        progress
            .actor_states
            .insert(progress.current_actor.clone(), "thinking".to_string());
    }
}

fn reset_round_progress(progress: &mut TurnProgressState) {
    if progress.actor_order.is_empty() {
        rebuild_actor_order(progress);
    }
    progress.actor_states.clear();
    for actor_id in &progress.actor_order {
        progress
            .actor_states
            .insert(actor_id.clone(), "pending".to_string());
    }
    progress.last_actor.clear();
    progress.last_result.clear();
    progress.current_actor.clear();
    progress.next_actor.clear();
    if !progress.actor_order.is_empty() {
        mark_current_and_next(progress, 0);
    }
}

fn complete_actor(progress: &mut TurnProgressState, actor_id: &str, result: &str) {
    let actor_id = actor_id.trim();
    if actor_id.is_empty() {
        return;
    }
    if progress.actor_order.is_empty() {
        rebuild_actor_order(progress);
    }

    progress
        .actor_states
        .insert(actor_id.to_string(), result.to_string());
    progress.last_actor = actor_id.to_string();
    progress.last_result = result.to_string();

    let actor_index = progress
        .actor_order
        .iter()
        .position(|id| id == actor_id)
        .or_else(|| {
            if progress.current_actor.is_empty() {
                None
            } else {
                progress
                    .actor_order
                    .iter()
                    .position(|id| id == &progress.current_actor)
            }
        });

    match actor_index {
        Some(idx) => {
            let next_idx = idx.saturating_add(1);
            if next_idx < progress.actor_order.len() {
                mark_current_and_next(progress, next_idx);
            } else {
                progress.current_actor.clear();
                progress.next_actor.clear();
            }
        }
        None => {
            progress.current_actor.clear();
            progress.next_actor.clear();
        }
    }
}

/// Reset runtime turn progress when entering TRPG mode or switching rooms.
pub fn reset_turn_progress(mut progress: ResMut<TurnProgressState>) {
    *progress = TurnProgressState::default();
}

/// Apply HP change events to Actor components.
pub fn apply_hp_change(
    mut events: MessageReader<HpChanged>,
    mut actors: Query<&mut Actor>,
) {
    for HpChanged(payload) in events.read() {
        for mut actor in &mut actors {
            if actor.id == payload.target {
                actor.hp = payload.remaining_hp;
                if actor.hp <= 0 {
                    actor.is_dead = true;
                }
            }
        }
    }
}

/// Apply area move events to Actor components.
pub fn apply_area_move(
    mut events: MessageReader<AreaMoved>,
    mut actors: Query<&mut Actor>,
    mut map_state: ResMut<MapState>,
) {
    for AreaMoved(payload) in events.read() {
        for mut actor in &mut actors {
            if actor.id == payload.character {
                actor.area = payload.to_area.clone();
            }
        }
        // Update the current map area to the most recently moved-to area
        map_state.current_area = payload.to_area.clone();
    }
}

/// Apply turn advance events to global room state.
pub fn apply_turn_advance(
    mut events: MessageReader<TurnAdvanced>,
    mut room_state: ResMut<RoomState>,
) {
    for TurnAdvanced(payload) in events.read() {
        room_state.turn = payload.turn;
        room_state.phase = TurnPhase::from_str(&payload.phase);
    }
}

/// Apply stream progress events to runtime turn progress state.
pub fn apply_turn_progress(
    mut events: MessageReader<TurnProgressUpdated>,
    mut progress: ResMut<TurnProgressState>,
    room_state: Res<RoomState>,
) {
    for TurnProgressUpdated(payload) in events.read() {
        if payload.turn > 0 {
            progress.turn = payload.turn;
        }
        if !payload.phase.is_empty() {
            progress.phase = payload.phase.clone();
        }
        if !payload.room_status.is_empty() {
            progress.room_status = payload.room_status.clone();
        }
        if !payload.dm_keeper.is_empty() {
            progress.dm_keeper = payload.dm_keeper.clone();
        }
        if !payload.selected_player_ids.is_empty() {
            progress.player_order = payload.selected_player_ids.clone();
            rebuild_actor_order(&mut progress);
        }
        if !payload.keeper.is_empty() {
            let actor_id = payload.actor_id.trim();
            if !actor_id.is_empty() {
                progress
                    .actor_states
                    .entry(actor_id.to_string())
                    .or_insert_with(|| "pending".to_string());
            }
        }

        progress.last_event = payload.event_type.clone();

        match payload.event_type.as_str() {
            "phase.changed" => {
                if progress.phase == "round" {
                    reset_round_progress(&mut progress);
                }
            }
            "turn.started" => {
                if payload.turn > 0 {
                    progress.turn = payload.turn;
                }
                progress.current_actor.clear();
                progress.next_actor.clear();
            }
            "narration.posted" => {
                let actor_id = if payload.actor_id.is_empty() {
                    "dm"
                } else {
                    payload.actor_id.as_str()
                };
                complete_actor(&mut progress, actor_id, "ok");
            }
            "turn.action.proposed" => {
                complete_actor(&mut progress, &payload.actor_id, "ok");
            }
            "turn.timeout" => {
                complete_actor(&mut progress, &payload.actor_id, "timeout");
            }
            "keeper.unavailable" => {
                complete_actor(&mut progress, &payload.actor_id, "unavailable");
            }
            "room.started" => {
                if progress.room_status.is_empty() {
                    progress.room_status = "active".to_string();
                }
            }
            "room.ended" => {
                progress.room_status = "ended".to_string();
                progress.current_actor.clear();
                progress.next_actor.clear();
            }
            _ => {}
        }
    }

    if progress.turn == 0 {
        progress.turn = room_state.turn;
    }
    if progress.phase.is_empty() {
        progress.phase = room_state.phase.as_str().to_string();
    }
    if progress.room_status.is_empty() {
        progress.room_status = room_state.status.clone();
    }
}

/// Apply item acquisition events to Actor inventory.
pub fn apply_item_acquired(
    mut events: MessageReader<ItemAcquired>,
    mut actors: Query<&mut Actor>,
) {
    for ItemAcquired(payload) in events.read() {
        for mut actor in &mut actors {
            if actor.id == payload.character {
                actor.inventory.push(payload.item.clone());
            }
        }
    }
}

/// Apply weather change events to OverlayState.
pub fn apply_weather_change(
    mut events: MessageReader<WeatherChanged>,
    mut overlay_state: ResMut<OverlayState>,
) {
    for WeatherChanged(payload) in events.read() {
        overlay_state.weather = payload.weather.clone();
    }
}

/// Apply mood change events to OverlayState.
pub fn apply_mood_change(
    mut events: MessageReader<MoodChanged>,
    mut overlay_state: ResMut<OverlayState>,
) {
    for MoodChanged(payload) in events.read() {
        overlay_state.mood = payload.mood.clone();
    }
}

/// Apply character death events.
pub fn apply_character_death(
    mut events: MessageReader<CharacterDied>,
    mut actors: Query<&mut Actor>,
) {
    for CharacterDied(payload) in events.read() {
        for mut actor in &mut actors {
            if actor.id == payload.character {
                actor.is_dead = true;
                actor.hp = 0;
            }
        }
    }
}

/// Apply choice available events to ChoiceState.
pub fn apply_choice_available(
    mut events: MessageReader<ChoiceAvailable>,
    mut choice_state: ResMut<ChoiceState>,
) {
    for ChoiceAvailable(payload) in events.read() {
        choice_state.active = true;
        choice_state.character = payload.character.clone();
        choice_state.description = payload.description.clone();
        choice_state.options = payload.options.clone();
    }
}

/// Apply choice resolved events — deactivate choice state.
pub fn apply_choice_resolved(
    mut events: MessageReader<ChoiceResolved>,
    mut choice_state: ResMut<ChoiceState>,
) {
    for ChoiceResolved(_payload) in events.read() {
        choice_state.active = false;
    }
}

/// Apply combat started events to CombatState.
pub fn apply_combat_started(
    mut events: MessageReader<CombatStarted>,
    mut combat_state: ResMut<CombatState>,
) {
    for CombatStarted(payload) in events.read() {
        combat_state.active = true;
        combat_state.area = payload.area.clone();
        combat_state.enemies = payload.enemies.clone();
    }
}
