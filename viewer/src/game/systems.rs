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

/// Reset runtime turn progress when entering TRPG mode or switching workspaces.
pub fn reset_turn_progress(mut progress: ResMut<TurnProgressState>) {
    *progress = TurnProgressState::default();
}

/// Apply HP change events to Actor components.
/// Validates that `amount` and `remaining_hp` are arithmetically consistent
/// with the actor's current HP. Logs a warning on mismatch (server-side bug
/// indicator) but still applies `remaining_hp` as the authoritative value.
pub fn apply_hp_change(mut events: MessageReader<HpChanged>, mut actors: Query<&mut Actor>) {
    for HpChanged(payload) in events.read() {
        for mut actor in &mut actors {
            if actor.id == payload.target {
                if payload.amount == 0 && actor.hp == payload.remaining_hp {
                    continue;
                }

                // Validate: actor.hp + amount should equal remaining_hp.
                // Use saturating_add to guard against extreme server values.
                let expected = actor.hp.saturating_add(payload.amount).clamp(0, actor.max_hp);
                if expected != payload.remaining_hp {
                    log::warn!(
                        "HP mismatch for {}: hp={} + amount={} = expected {} but server sent remaining_hp={}",
                        actor.id, actor.hp, payload.amount, expected, payload.remaining_hp,
                    );
                }

                actor.hp = payload.remaining_hp.clamp(0, actor.max_hp);
                actor.is_dead = actor.hp <= 0;
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

/// Apply turn advance events to global workspace state.
pub fn apply_turn_advance(
    mut events: MessageReader<TurnAdvanced>,
    mut workspace_state: ResMut<WorkspaceState>,
) {
    for TurnAdvanced(payload) in events.read() {
        if !payload.workspace_id.is_empty() {
            workspace_state.id = payload.workspace_id.clone();
        }
        workspace_state.turn = payload.turn;
        workspace_state.phase = TurnPhase::from_str(&payload.phase);
    }
}

/// Apply stream progress events to runtime turn progress state.
pub fn apply_turn_progress(
    mut events: MessageReader<TurnProgressUpdated>,
    mut progress: ResMut<TurnProgressState>,
    workspace_state: Res<WorkspaceState>,
) {
    for TurnProgressUpdated(payload) in events.read() {
        if payload.turn > 0 {
            progress.turn = payload.turn;
        }
        if !payload.phase.is_empty() {
            progress.phase = payload.phase.clone();
        }
        if !payload.workspace_status.is_empty() {
            progress.workspace_status = payload.workspace_status.clone();
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
            "workspace.started" => {
                if progress.workspace_status.is_empty() {
                    progress.workspace_status = "active".to_string();
                }
                progress.actor_reasons.clear();
            }
            "workspace.ended" => {
                progress.workspace_status = "ended".to_string();
                progress.current_actor.clear();
                progress.next_actor.clear();
                progress.actor_reasons.clear();
            }
            "session.outcome" => {
                progress.workspace_status = "ended".to_string();
                progress.current_actor.clear();
                progress.next_actor.clear();
                progress.actor_reasons.clear();
            }
            _ => {}
        }

        // Phase inference removed: apply_phase_changed is the canonical
        // source for workspace_state.phase. Inferring phase from event types here
        // caused conflicts when phase.changed events arrived at different
        // timing than progress events.
    }

    if progress.turn == 0 {
        progress.turn = workspace_state.turn;
    }
    if progress.phase.is_empty() {
        progress.phase = workspace_state.phase.as_str().to_string();
    }
    if progress.workspace_status.is_empty() {
        progress.workspace_status = workspace_state.status.clone();
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
        // Use nested actor data from server when available; fall back to
        // payload-level fields / sensible defaults for older event formats.
        let data = payload.actor.as_ref();
        let server_max_hp = data.and_then(|d| d.max_hp).unwrap_or(10);
        let server_hp = data
            .and_then(|d| d.hp)
            .unwrap_or(server_max_hp)
            .min(server_max_hp);
        let actor = Actor {
            id: payload.actor_id.clone(),
            name: data
                .map(|d| &d.name)
                .filter(|n| !n.is_empty())
                .cloned()
                .unwrap_or_else(|| {
                    if payload.name.is_empty() {
                        payload.actor_id.clone()
                    } else {
                        payload.name.clone()
                    }
                }),
            class: payload.class.clone(),
            archetype: data
                .map(|d| &d.archetype)
                .filter(|a| !a.is_empty())
                .cloned()
                .unwrap_or_else(|| payload.class.clone()),
            persona: data
                .map(|d| d.persona.clone())
                .unwrap_or_default(),
            traits: data
                .map(|d| d.traits.clone())
                .unwrap_or_default(),
            hp: server_hp,
            max_hp: server_max_hp,
            mp: 0,
            max_mp: 0,
            stats: Stats {
                atk: 10,
                def: 10,
                int: 10,
                luck: 10,
            },
            area: String::new(),
            is_dead: data
                .and_then(|d| d.alive)
                .map(|alive| !alive)
                .unwrap_or(false),
            inventory: data
                .map(|d| d.inventory.clone())
                .unwrap_or_default(),
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

/// Mark workspace as ended when WorkspaceEnded event fires.
pub fn apply_workspace_ended(
    mut events: MessageReader<WorkspaceEnded>,
    mut workspace_state: ResMut<WorkspaceState>,
    mut combat_state: ResMut<CombatState>,
) {
    for WorkspaceEnded(payload) in events.read() {
        if workspace_state.id == payload.workspace_id || payload.workspace_id.is_empty() {
            workspace_state.status = "ended".to_string();

            // Reset combat state when workspace ends
            if combat_state.active {
                combat_state.active = false;
                combat_state.area.clear();
                combat_state.enemies.clear();
            }
        }
    }
}

/// Update workspace state on scene transitions.
pub fn apply_scene_transitioned(
    mut events: MessageReader<SceneTransitioned>,
    mut workspace_state: ResMut<WorkspaceState>,
) {
    for SceneTransitioned(payload) in events.read() {
        workspace_state.current_scenario = payload.to_scene.clone();
    }
}

// --- Session / Turn lifecycle systems ---

pub fn apply_party_selected(
    mut events: MessageReader<PartySelected>,
    mut progress: ResMut<TurnProgressState>,
) {
    for PartySelected(p) in events.read() {
        if !p.selected_player_ids.is_empty() {
            progress.player_order = p.selected_player_ids.clone();
            rebuild_actor_order(&mut progress);
        }
    }
}

pub fn apply_workspace_created(
    mut events: MessageReader<WorkspaceCreated>,
    mut workspace_state: ResMut<WorkspaceState>,
) {
    for WorkspaceCreated(p) in events.read() {
        workspace_state.id = p.workspace_id.clone();
        workspace_state.status = "created".to_string();
    }
}

pub fn apply_workspace_started(
    mut events: MessageReader<WorkspaceStarted>,
    mut workspace_state: ResMut<WorkspaceState>,
) {
    for WorkspaceStarted(p) in events.read() {
        if !p.workspace_id.is_empty() {
            workspace_state.id = p.workspace_id.clone();
        }
        if !p.status.is_empty() {
            workspace_state.status = p.status.clone();
        } else {
            workspace_state.status = "started".to_string();
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
    mut workspace_state: ResMut<WorkspaceState>,
) {
    for PhaseChanged(p) in events.read() {
        if !p.workspace_id.is_empty() {
            workspace_state.id = p.workspace_id.clone();
        }
        workspace_state.phase = TurnPhase::from_str(&p.phase);
    }
}

pub fn apply_turn_started(
    mut events: MessageReader<TurnStarted>,
    mut workspace_state: ResMut<WorkspaceState>,
) {
    for TurnStarted(p) in events.read() {
        if !p.workspace_id.is_empty() {
            workspace_state.id = p.workspace_id.clone();
        }
        workspace_state.turn = p.turn;
        workspace_state.phase = TurnPhase::from_str(&p.phase);
    }
}

pub fn apply_turn_action_resolved(
    mut events: MessageReader<TurnActionResolved>,
    mut progress: ResMut<TurnProgressState>,
) {
    for TurnActionResolved(p) in events.read() {
        complete_actor(&mut progress, &p.actor_id, "ok");
        let reason = if p.result.is_empty() {
            p.action.clone()
        } else {
            format!("{}: {}", p.action, p.result)
        };
        set_actor_reason(&mut progress, &p.actor_id, &reason);
        progress.last_result = p.result.clone();
        progress.last_event = "turn.action.resolved".to_string();
    }
}

pub fn apply_combat_attack(
    mut events: MessageReader<CombatAttack>,
    mut workspace_state: ResMut<WorkspaceState>,
    mut progress: ResMut<TurnProgressState>,
) {
    for CombatAttack(payload) in events.read() {
        if payload.turn > 0 {
            workspace_state.turn = payload.turn;
            progress.turn = payload.turn;
        }
        let actor_id = payload.actor_id.trim();
        if !actor_id.is_empty() {
            progress.current_actor = actor_id.to_string();
            progress
                .actor_states
                .insert(actor_id.to_string(), "combat".to_string());
            if !payload.action.trim().is_empty() {
                set_actor_reason(&mut progress, actor_id, &payload.action);
            }
        }
    }
}

pub fn apply_combat_defense(
    mut events: MessageReader<CombatDefense>,
    mut workspace_state: ResMut<WorkspaceState>,
    mut progress: ResMut<TurnProgressState>,
) {
    for CombatDefense(payload) in events.read() {
        if payload.turn > 0 {
            workspace_state.turn = payload.turn;
            progress.turn = payload.turn;
        }
        let actor_id = payload.actor_id.trim();
        if !actor_id.is_empty() {
            progress.current_actor = actor_id.to_string();
            progress
                .actor_states
                .insert(actor_id.to_string(), "defending".to_string());
            if !payload.method.trim().is_empty() {
                set_actor_reason(
                    &mut progress,
                    actor_id,
                    &format!("defense: {}", payload.method.trim()),
                );
            }
        }
    }
}

pub fn apply_session_outcome(
    mut events: MessageReader<SessionOutcome>,
    mut workspace_state: ResMut<WorkspaceState>,
    mut progress: ResMut<TurnProgressState>,
    mut combat_state: ResMut<CombatState>,
) {
    for SessionOutcome(payload) in events.read() {
        workspace_state.status = "ended".to_string();
        if payload.turn > 0 {
            workspace_state.turn = payload.turn;
            progress.turn = payload.turn;
        }
        progress.workspace_status = "ended".to_string();
        let reason = payload.reason.trim();
        let source = payload.outcome_source.trim();
        let detail = if reason.is_empty() {
            source.to_string()
        } else if source.is_empty() {
            reason.to_string()
        } else {
            format!("{reason} · source={source}")
        };
        progress.last_result = if detail.is_empty() {
            payload.outcome.clone()
        } else {
            format!("{} ({})", payload.outcome, detail)
        };

        // Reset combat state when session ends
        if combat_state.active {
            combat_state.active = false;
            combat_state.area.clear();
            combat_state.enemies.clear();
        }
    }
}

pub fn apply_intervention_submitted(
    mut events: MessageReader<InterventionSubmitted>,
    mut progress: ResMut<TurnProgressState>,
) {
    for InterventionSubmitted(p) in events.read() {
        progress.last_event = format!("intervention.submitted:{}", p.intervention_type);
        if !p.target.is_empty() {
            set_actor_reason(&mut progress, &p.target, &p.description);
        }
    }
}

pub fn apply_intervention_applied(
    mut events: MessageReader<InterventionApplied>,
    mut progress: ResMut<TurnProgressState>,
) {
    for InterventionApplied(p) in events.read() {
        progress.last_event = format!("intervention.applied:{}", p.intervention_type);
        progress.last_result = p.description.clone();
        if !p.target.is_empty() {
            set_actor_reason(
                &mut progress,
                &p.target,
                &format!("[{}] {}", p.intervention_type, p.description),
            );
        }
    }
}

pub fn apply_keeper_unavailable(
    mut events: MessageReader<KeeperUnavailable>,
    mut progress: ResMut<TurnProgressState>,
) {
    for KeeperUnavailable(p) in events.read() {
        log::warn!("Keeper unavailable: {} — {}", p.keeper, p.reason);
        progress.last_event = format!("keeper.unavailable:{}", p.keeper);
        if progress.dm_keeper == p.keeper {
            progress.dm_keeper.clear();
        }
    }
}
