use bevy::prelude::*;

use super::components::*;
use super::events::*;
use super::state::*;

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
