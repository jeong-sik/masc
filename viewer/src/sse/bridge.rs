use bevy::ecs::system::SystemParam;
use bevy::prelude::*;

use super::client::SseReceiver;
use crate::game::events::*;
use crate::game::state::ConnectionStatus;

/// Parse SSE JSON data into a typed payload and write the corresponding Bevy message.
macro_rules! dispatch_event {
    ($event_type:expr, $data:expr, $writer:expr, $payload_ty:ty, $event_ty:ident) => {
        match serde_json::from_str::<$payload_ty>($data) {
            Ok(payload) => {
                $writer.write($event_ty(payload));
            }
            Err(e) => log::warn!("Failed to parse {}: {}", $event_type, e),
        }
    };
}

// ── SystemParam bundles ──────────────────────────
// Bevy's IntoSystem supports max 16 params. Bundle MessageWriters into
// logical groups so the system function stays under the limit.

/// Original 13 event types (underscore-format SSE names).
#[derive(SystemParam)]
pub struct OriginalEventWriters<'w> {
    pub dice: MessageWriter<'w, DiceRolled>,
    pub hp: MessageWriter<'w, HpChanged>,
    pub narrative: MessageWriter<'w, NarrativeReceived>,
    pub area: MessageWriter<'w, AreaMoved>,
    pub turn: MessageWriter<'w, TurnAdvanced>,
    pub choice: MessageWriter<'w, ChoiceAvailable>,
    pub choice_resolved: MessageWriter<'w, ChoiceResolved>,
    pub item: MessageWriter<'w, ItemAcquired>,
    pub death: MessageWriter<'w, CharacterDied>,
    pub combat: MessageWriter<'w, CombatStarted>,
    pub weather: MessageWriter<'w, WeatherChanged>,
    pub mood: MessageWriter<'w, MoodChanged>,
    pub progress: MessageWriter<'w, TurnProgressUpdated>,
}

/// Phase 1: High-frequency lifecycle events (dot-format SSE names).
#[derive(SystemParam)]
pub struct Phase1EventWriters<'w> {
    pub party_selected: MessageWriter<'w, PartySelected>,
    pub workspace_created: MessageWriter<'w, WorkspaceCreated>,
    pub workspace_started: MessageWriter<'w, WorkspaceStarted>,
    pub session_started: MessageWriter<'w, SessionStarted>,
    pub phase_changed: MessageWriter<'w, PhaseChanged>,
    pub turn_started: MessageWriter<'w, TurnStarted>,
    pub keeper_unavailable: MessageWriter<'w, KeeperUnavailable>,
}

/// Phase 2: Intervention + Actor events (dot-format SSE names).
#[derive(SystemParam)]
pub struct Phase2EventWriters<'w> {
    pub intervention_submitted: MessageWriter<'w, InterventionSubmitted>,
    pub intervention_applied: MessageWriter<'w, InterventionApplied>,
    pub actor_spawned: MessageWriter<'w, ActorSpawned>,
    pub actor_deleted: MessageWriter<'w, ActorDeleted>,
    pub actor_claimed: MessageWriter<'w, ActorClaimed>,
    pub actor_released: MessageWriter<'w, ActorReleased>,
    pub actor_updated: MessageWriter<'w, ActorUpdated>,
    pub workspace_ended: MessageWriter<'w, WorkspaceEnded>,
    pub turn_action_resolved: MessageWriter<'w, TurnActionResolved>,
    pub combat_attack: MessageWriter<'w, CombatAttack>,
    pub combat_defense: MessageWriter<'w, CombatDefense>,
    pub session_outcome: MessageWriter<'w, SessionOutcome>,
    pub scene_transitioned: MessageWriter<'w, SceneTransitioned>,
}

/// Each frame, drain the SSE message buffer and emit typed Bevy events.
pub fn poll_sse_events(
    receiver: Option<Res<SseReceiver>>,
    mut original: OriginalEventWriters,
    mut phase1: Phase1EventWriters,
    mut phase2: Phase2EventWriters,
    mut connection: ResMut<ConnectionStatus>,
) {
    let Some(receiver) = receiver else { return };

    let mut msgs = match receiver.messages.lock() {
        Ok(guard) => guard,
        Err(_) => return,
    };

    if !msgs.is_empty() {
        // We received data, so we're connected
        *connection = ConnectionStatus::Connected;
    }

    for (event_type, data) in msgs.drain(..) {
        match event_type.as_str() {
            // ── Original events (underscore format) ──
            "dice_roll" => dispatch_event!(
                event_type,
                &data,
                original.dice,
                DiceRollPayload,
                DiceRolled
            ),
            "hp_change" => {
                dispatch_event!(event_type, &data, original.hp, HpChangePayload, HpChanged)
            }
            "narrative" => dispatch_event!(
                event_type,
                &data,
                original.narrative,
                NarrativePayload,
                NarrativeReceived
            ),
            "area_move" => {
                dispatch_event!(event_type, &data, original.area, AreaMovePayload, AreaMoved)
            }
            "turn_advance" => dispatch_event!(
                event_type,
                &data,
                original.turn,
                TurnAdvancePayload,
                TurnAdvanced
            ),
            "choice_available" => dispatch_event!(
                event_type,
                &data,
                original.choice,
                ChoicePayload,
                ChoiceAvailable
            ),
            "choice_resolved" => dispatch_event!(
                event_type,
                &data,
                original.choice_resolved,
                ChoicePayload,
                ChoiceResolved
            ),
            "item_acquired" => {
                dispatch_event!(event_type, &data, original.item, ItemPayload, ItemAcquired)
            }
            "character_death" => dispatch_event!(
                event_type,
                &data,
                original.death,
                DeathPayload,
                CharacterDied
            ),
            "combat_start" => dispatch_event!(
                event_type,
                &data,
                original.combat,
                CombatPayload,
                CombatStarted
            ),
            "weather_change" => dispatch_event!(
                event_type,
                &data,
                original.weather,
                WeatherChangePayload,
                WeatherChanged
            ),
            "mood_change" => dispatch_event!(
                event_type,
                &data,
                original.mood,
                MoodChangePayload,
                MoodChanged
            ),
            "turn_progress" => dispatch_event!(
                event_type,
                &data,
                original.progress,
                TurnProgressPayload,
                TurnProgressUpdated
            ),
            // ── Dot-format aliases for original events ──
            // Server sends "dice.rolled" via MASC API; reuse original writer.
            "dice.rolled" => dispatch_event!(
                event_type,
                &data,
                original.dice,
                DiceRollPayload,
                DiceRolled
            ),
            // ── Phase 1: High-frequency events (dot format) ──
            "party.selected" => dispatch_event!(
                event_type,
                &data,
                phase1.party_selected,
                PartySelectedPayload,
                PartySelected
            ),
            "workspace.created" => dispatch_event!(
                event_type,
                &data,
                phase1.workspace_created,
                WorkspaceCreatedPayload,
                WorkspaceCreated
            ),
            "workspace.started" => dispatch_event!(
                event_type,
                &data,
                phase1.workspace_started,
                WorkspaceLifecyclePayload,
                WorkspaceStarted
            ),
            "session.started" => dispatch_event!(
                event_type,
                &data,
                phase1.session_started,
                SessionStartedPayload,
                SessionStarted
            ),
            "phase.changed" => dispatch_event!(
                event_type,
                &data,
                phase1.phase_changed,
                TurnAdvancePayload,
                PhaseChanged
            ),
            "turn.started" => dispatch_event!(
                event_type,
                &data,
                phase1.turn_started,
                TurnAdvancePayload,
                TurnStarted
            ),
            "keeper.unavailable" => dispatch_event!(
                event_type,
                &data,
                phase1.keeper_unavailable,
                KeeperUnavailablePayload,
                KeeperUnavailable
            ),
            // ── Phase 2: Intervention + Actor events (dot format) ──
            "intervention.submitted" => dispatch_event!(
                event_type,
                &data,
                phase2.intervention_submitted,
                InterventionPayload,
                InterventionSubmitted
            ),
            "intervention.applied" => dispatch_event!(
                event_type,
                &data,
                phase2.intervention_applied,
                InterventionPayload,
                InterventionApplied
            ),
            "actor.spawned" => dispatch_event!(
                event_type,
                &data,
                phase2.actor_spawned,
                ActorLifecyclePayload,
                ActorSpawned
            ),
            "actor.deleted" => dispatch_event!(
                event_type,
                &data,
                phase2.actor_deleted,
                ActorLifecyclePayload,
                ActorDeleted
            ),
            "actor.claimed" => dispatch_event!(
                event_type,
                &data,
                phase2.actor_claimed,
                ActorLifecyclePayload,
                ActorClaimed
            ),
            "actor.released" => dispatch_event!(
                event_type,
                &data,
                phase2.actor_released,
                ActorLifecyclePayload,
                ActorReleased
            ),
            "actor.updated" => dispatch_event!(
                event_type,
                &data,
                phase2.actor_updated,
                ActorLifecyclePayload,
                ActorUpdated
            ),
            "workspace.ended" => dispatch_event!(
                event_type,
                &data,
                phase2.workspace_ended,
                WorkspaceEndedPayload,
                WorkspaceEnded
            ),
            "turn.action.resolved" => dispatch_event!(
                event_type,
                &data,
                phase2.turn_action_resolved,
                TurnActionResolvedPayload,
                TurnActionResolved
            ),
            "combat.attack" => dispatch_event!(
                event_type,
                &data,
                phase2.combat_attack,
                CombatAttackPayload,
                CombatAttack
            ),
            "combat.defense" => dispatch_event!(
                event_type,
                &data,
                phase2.combat_defense,
                CombatDefensePayload,
                CombatDefense
            ),
            "session.outcome" => dispatch_event!(
                event_type,
                &data,
                phase2.session_outcome,
                SessionOutcomePayload,
                SessionOutcome
            ),
            "scene.transition" => dispatch_event!(
                event_type,
                &data,
                phase2.scene_transitioned,
                SceneTransitionPayload,
                SceneTransitioned
            ),
            // ── Fallback ──
            other => {
                log::debug!("Unhandled SSE event type: {}", other);
            }
        }
    }
}
