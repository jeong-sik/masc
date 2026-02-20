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

fn set_actor_reason(progress: &mut TurnProgressState, actor_id: &str, reason: &str) {
    let actor_id = actor_id.trim();
    if actor_id.is_empty() {
        return;
    }
    let reason = reason.trim();
    if reason.is_empty() {
        progress.actor_reasons.remove(actor_id);
    } else {
        progress
            .actor_reasons
            .insert(actor_id.to_string(), reason.to_string());
    }
}

fn reset_round_progress(progress: &mut TurnProgressState) {
    if progress.actor_order.is_empty() {
        rebuild_actor_order(progress);
    }
    progress.actor_states.clear();
    progress.actor_reasons.clear();
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
pub fn apply_hp_change(mut events: MessageReader<HpChanged>, mut actors: Query<&mut Actor>) {
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
        if !payload.room_id.is_empty() {
            room_state.id = payload.room_id.clone();
        }
        room_state.turn = payload.turn;
        room_state.phase = TurnPhase::from_str(&payload.phase);
    }
}

/// Apply stream progress events to runtime turn progress state.
pub fn apply_turn_progress(
    mut events: MessageReader<TurnProgressUpdated>,
    mut progress: ResMut<TurnProgressState>,
    mut room_state: ResMut<RoomState>,
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
                // Phase change is handled by inference below or TurnStarted
            }
            "turn.started" => {
                if payload.turn > 0 {
                    progress.turn = payload.turn;
                }
                progress.actor_reasons.clear();
                // Start with the first actor in the order
                mark_current_and_next(&mut progress, 0);
            }
            "narration.posted" => {
                let actor_id = if payload.actor_id.is_empty() {
                    "dm"
                } else {
                    payload.actor_id.as_str()
                };
                complete_actor(&mut progress, actor_id, "ok");
                set_actor_reason(&mut progress, actor_id, "");
            }
            "turn.action.proposed" => {
                complete_actor(&mut progress, &payload.actor_id, "ok");
                set_actor_reason(&mut progress, &payload.actor_id, "");
            }
            "turn.timeout" => {
                complete_actor(&mut progress, &payload.actor_id, "timeout");
                set_actor_reason(&mut progress, &payload.actor_id, &payload.reason);
            }
            "keeper.unavailable" => {
                complete_actor(&mut progress, &payload.actor_id, "unavailable");
                set_actor_reason(&mut progress, &payload.actor_id, &payload.reason);
            }
            "combat.attack" | "combat.defense" => {
                let actor_id = payload.actor_id.trim();
                if !actor_id.is_empty() {
                    complete_actor(&mut progress, actor_id, "ok");
                    set_actor_reason(&mut progress, actor_id, "");
                }
            }
            "room.started" => {
                if progress.room_status.is_empty() {
                    progress.room_status = "active".to_string();
                }
                progress.actor_reasons.clear();
            }
            "room.ended" => {
                progress.room_status = "ended".to_string();
                progress.current_actor.clear();
                progress.next_actor.clear();
                progress.actor_reasons.clear();
            }
            "session.outcome" => {
                progress.room_status = "ended".to_string();
                progress.current_actor.clear();
                progress.next_actor.clear();
                progress.actor_reasons.clear();
            }
            _ => {}
        }

        // Infer UI Phase from event type
        let inferred_phase = match payload.event_type.as_str() {
            "turn.started" => Some(TurnPhase::ActionDeclaration),
            "turn.action.proposed" | "intervention.submitted" => Some(TurnPhase::DiceResolution),
            "dice.rolled" => Some(TurnPhase::OutcomeNarration),
            "narration.posted" => Some(TurnPhase::DmNarration),
            _ => None,
        };

        if let Some(p) = inferred_phase {
            room_state.phase = p;
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
pub fn apply_item_acquired(mut events: MessageReader<ItemAcquired>, mut actors: Query<&mut Actor>) {
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

// ─── Actor Lifecycle Systems ────────────────────

/// Spawn a new Actor entity when ActorSpawned fires.
/// Skips if an actor with the same ID already exists (idempotent).
pub fn apply_actor_spawned(
    mut events: MessageReader<ActorSpawned>,
    mut commands: Commands,
    existing: Query<&Actor>,
) {
    for ActorSpawned(payload) in events.read() {
        if existing.iter().any(|a| a.id == payload.actor_id) {
            continue;
        }
        let actor = Actor {
            id: payload.actor_id.clone(),
            name: if payload.name.is_empty() {
                payload.actor_id.clone()
            } else {
                payload.name.clone()
            },
            class: payload.class.clone(),
            archetype: payload.class.clone(),
            persona: String::new(),
            traits: Vec::new(),
            hp: 100,
            max_hp: 100,
            mp: 50,
            max_mp: 50,
            stats: Stats {
                atk: 10,
                def: 10,
                int: 10,
                luck: 10,
            },
            area: String::new(),
            is_dead: false,
            inventory: Vec::new(),
            buffs: Vec::new(),
            debuffs: Vec::new(),
            skills: Vec::new(),
            conditions: Vec::new(),
            equipment: Vec::new(),
            keeper: payload.keeper.clone(),
        };
        commands.spawn((actor, MapToken));
    }
}

/// Update Actor fields when ActorUpdated fires.
/// Only overwrites non-empty payload fields.
pub fn apply_actor_updated(mut events: MessageReader<ActorUpdated>, mut actors: Query<&mut Actor>) {
    for ActorUpdated(payload) in events.read() {
        for mut actor in &mut actors {
            if actor.id == payload.actor_id {
                if !payload.name.is_empty() {
                    actor.name = payload.name.clone();
                }
                if !payload.class.is_empty() {
                    actor.class = payload.class.clone();
                }
                if !payload.keeper.is_empty() {
                    actor.keeper = payload.keeper.clone();
                }
            }
        }
    }
}

/// Despawn Actor entity when ActorDeleted fires.
pub fn apply_actor_deleted(
    mut events: MessageReader<ActorDeleted>,
    mut commands: Commands,
    actors: Query<(Entity, &Actor)>,
) {
    for ActorDeleted(payload) in events.read() {
        for (entity, actor) in &actors {
            if actor.id == payload.actor_id {
                commands.entity(entity).despawn();
            }
        }
    }
}

/// Bind a keeper to an Actor when ActorClaimed fires.
pub fn apply_actor_claimed(mut events: MessageReader<ActorClaimed>, mut actors: Query<&mut Actor>) {
    for ActorClaimed(payload) in events.read() {
        for mut actor in &mut actors {
            if actor.id == payload.actor_id {
                actor.keeper = payload.keeper.clone();
            }
        }
    }
}

/// Unbind a keeper from an Actor when ActorReleased fires.
pub fn apply_actor_released(
    mut events: MessageReader<ActorReleased>,
    mut actors: Query<&mut Actor>,
) {
    for ActorReleased(payload) in events.read() {
        for mut actor in &mut actors {
            if actor.id == payload.actor_id {
                actor.keeper.clear();
            }
        }
    }
}

/// Mark room as ended when RoomEnded event fires.
pub fn apply_room_ended(mut events: MessageReader<RoomEnded>, mut room_state: ResMut<RoomState>) {
    for RoomEnded(payload) in events.read() {
        if room_state.id == payload.room_id || payload.room_id.is_empty() {
            room_state.status = "ended".to_string();
        }
    }
}

/// Update room state on scene transitions.
pub fn apply_scene_transitioned(
    mut events: MessageReader<SceneTransitioned>,
    mut room_state: ResMut<RoomState>,
) {
    for SceneTransitioned(payload) in events.read() {
        room_state.current_scenario = payload.to_scene.clone();
    }
}

// --- Session / Turn lifecycle systems ---

pub fn apply_party_selected(mut events: MessageReader<PartySelected>) {
    for PartySelected(_p) in events.read() {
        // Log-only: no ECS state mutation needed
    }
}

pub fn apply_room_created(
    mut events: MessageReader<RoomCreated>,
    mut room_state: ResMut<RoomState>,
) {
    for RoomCreated(p) in events.read() {
        room_state.id = p.room_id.clone();
        room_state.status = "created".to_string();
    }
}

pub fn apply_room_started(
    mut events: MessageReader<RoomStarted>,
    mut room_state: ResMut<RoomState>,
) {
    for RoomStarted(p) in events.read() {
        if !p.room_id.is_empty() {
            room_state.id = p.room_id.clone();
        }
        if !p.status.is_empty() {
            room_state.status = p.status.clone();
        } else {
            room_state.status = "started".to_string();
        }
    }
}

pub fn apply_session_started(mut events: MessageReader<SessionStarted>) {
    for SessionStarted(_p) in events.read() {
        // Log-only: session ID is informational
    }
}

pub fn apply_phase_changed(
    mut events: MessageReader<PhaseChanged>,
    mut room_state: ResMut<RoomState>,
) {
    for PhaseChanged(p) in events.read() {
        if !p.room_id.is_empty() {
            room_state.id = p.room_id.clone();
        }
        room_state.phase = TurnPhase::from_str(&p.phase);
    }
}

pub fn apply_turn_started(
    mut events: MessageReader<TurnStarted>,
    mut room_state: ResMut<RoomState>,
) {
    for TurnStarted(p) in events.read() {
        if !p.room_id.is_empty() {
            room_state.id = p.room_id.clone();
        }
        room_state.turn = p.turn;
        room_state.phase = TurnPhase::from_str(&p.phase);
    }
}

pub fn apply_turn_action_resolved(mut events: MessageReader<TurnActionResolved>) {
    for TurnActionResolved(_p) in events.read() {
        // Log-only: action result is rendered by DOM system
    }
}

pub fn apply_combat_attack(mut events: MessageReader<CombatAttack>) {
    for CombatAttack(_p) in events.read() {
        // Log-only: semantic combat event rendered by DOM systems
    }
}

pub fn apply_combat_defense(mut events: MessageReader<CombatDefense>) {
    for CombatDefense(_p) in events.read() {
        // Log-only: semantic combat event rendered by DOM systems
    }
}

pub fn apply_session_outcome(
    mut events: MessageReader<SessionOutcome>,
    mut room_state: ResMut<RoomState>,
    mut progress: ResMut<TurnProgressState>,
) {
    for SessionOutcome(payload) in events.read() {
        room_state.status = "ended".to_string();
        if payload.turn > 0 {
            room_state.turn = payload.turn;
            progress.turn = payload.turn;
        }
        progress.room_status = "ended".to_string();
    }
}

pub fn apply_intervention_submitted(mut events: MessageReader<InterventionSubmitted>) {
    for InterventionSubmitted(_p) in events.read() {
        // Log-only: rendered by DOM system
    }
}

pub fn apply_intervention_applied(mut events: MessageReader<InterventionApplied>) {
    for InterventionApplied(_p) in events.read() {
        // Log-only: rendered by DOM system
    }
}

pub fn apply_keeper_unavailable(mut events: MessageReader<KeeperUnavailable>) {
    for KeeperUnavailable(_p) in events.read() {
        // Log-only: warning rendered by DOM system
    }
}
