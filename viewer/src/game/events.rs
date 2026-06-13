use bevy::prelude::*;
use serde::Deserialize;

// ─── SSE Payload Types ────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct DiceRollPayload {
    #[serde(default)]
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub turn: u32,
    #[serde(default)]
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub workspace_id: String,
    /// Server sends `actor_id`; legacy SSE sends `character`.
    #[serde(default, alias = "actor_id")]
    pub character: String,
    #[serde(default)]
    pub action: String,
    /// Server sends `raw_d20`; legacy SSE sends `d20`.
    #[serde(default, alias = "raw_d20")]
    pub d20: i32,
    #[serde(default)]
    pub bonus: i32,
    #[serde(default)]
    pub total: i32,
    #[serde(default)]
    pub dc: i32,
    pub result: String,
    #[serde(default)]
    pub note: Option<String>,
    // ── D&D 5e Lite fields (from server) ──
    /// Roll tier classification: "critical_fail" | "fail" | "partial" | "success" | "great" | "miracle"
    #[serde(default)]
    pub tier: Option<String>,
    /// Korean display label: "대참사" | "실패" | "부분 성공" | "성공" | "대성공" | "기적"
    #[serde(default)]
    pub label: Option<String>,
    /// Whether the roll passed the DC check
    #[serde(default)]
    pub passed: Option<bool>,
    /// Raw stat value used for the roll
    #[serde(default)]
    pub stat_value: Option<i32>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct HpChangePayload {
    pub target: String,
    pub amount: i32,
    pub remaining_hp: i32,
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub source: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NarrativePayload {
    pub text: String,
    pub phase: String,
    #[serde(default)]
    pub turn: u32,
    #[serde(default)]
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub workspace_id: String,
    #[serde(default)]
    pub speaker: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AreaMovePayload {
    pub character: String,
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub from_area: String,
    pub to_area: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TurnAdvancePayload {
    pub turn: u32,
    pub phase: String,
    #[serde(default)]
    pub workspace_id: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ChoicePayload {
    pub character: String,
    pub description: String,
    #[serde(default)]
    pub options: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ItemPayload {
    pub character: String,
    pub item: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DeathPayload {
    pub character: String,
    pub cause: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CombatPayload {
    pub area: String,
    #[serde(default)]
    pub enemies: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WeatherChangePayload {
    pub weather: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MoodChangePayload {
    pub mood: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TurnProgressPayload {
    pub event_type: String,
    #[serde(default)]
    pub turn: u32,
    #[serde(default)]
    pub phase: String,
    #[serde(default)]
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub workspace_id: String,
    #[serde(default)]
    pub actor_id: String,
    #[serde(default)]
    pub keeper: String,
    #[serde(default)]
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub role: String,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub workspace_status: String,
    #[serde(default)]
    pub dm_keeper: String,
    #[serde(default)]
    pub selected_player_ids: Vec<String>,
}

// ─── Bevy Events ──────────────────────────

#[derive(Message, Debug, Clone)]
pub struct DiceRolled(pub DiceRollPayload);

#[derive(Message, Debug, Clone)]
pub struct HpChanged(pub HpChangePayload);

#[derive(Message, Debug, Clone)]
pub struct NarrativeReceived(pub NarrativePayload);

#[derive(Message, Debug, Clone)]
pub struct AreaMoved(pub AreaMovePayload);

#[derive(Message, Debug, Clone)]
pub struct TurnAdvanced(pub TurnAdvancePayload);

#[derive(Message, Debug, Clone)]
pub struct ChoiceAvailable(pub ChoicePayload);

#[derive(Message, Debug, Clone)]
pub struct ChoiceResolved(pub ChoicePayload);

#[derive(Message, Debug, Clone)]
pub struct ItemAcquired(pub ItemPayload);

#[derive(Message, Debug, Clone)]
pub struct CharacterDied(pub DeathPayload);

#[derive(Message, Debug, Clone)]
pub struct CombatStarted(pub CombatPayload);

#[derive(Message, Debug, Clone)]
pub struct WeatherChanged(pub WeatherChangePayload);

#[derive(Message, Debug, Clone)]
pub struct MoodChanged(pub MoodChangePayload);

#[derive(Message, Debug, Clone)]
pub struct TurnProgressUpdated(pub TurnProgressPayload);

// ─── Phase 1: High-Frequency Events ─────────

// Fields populated by serde deserialization; read only in wasm32 DOM code.
#[allow(dead_code)]
#[derive(Debug, Clone, Deserialize)]
pub struct PartySelectedPayload {
    pub workspace_id: String,
    #[serde(default)]
    pub selected_player_ids: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WorkspaceCreatedPayload {
    pub workspace_id: String,
    #[serde(default)]
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub preset: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WorkspaceLifecyclePayload {
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub workspace_id: String,
    #[serde(default)]
    pub status: String,
}

// Fields populated by serde deserialization; read only in wasm32 DOM code.
#[allow(dead_code)]
#[derive(Debug, Clone, Deserialize)]
pub struct SessionStartedPayload {
    pub workspace_id: String,
    #[serde(default)]
    pub session_id: String,
}

// Fields populated by serde deserialization; read only in wasm32 DOM code.
#[allow(dead_code)]
#[derive(Debug, Clone, Deserialize)]
pub struct KeeperUnavailablePayload {
    pub keeper: String,
    #[serde(default)]
    pub reason: String,
}

#[derive(Message, Debug, Clone)]
pub struct PartySelected(pub PartySelectedPayload);

#[derive(Message, Debug, Clone)]
pub struct WorkspaceCreated(pub WorkspaceCreatedPayload);

#[derive(Message, Debug, Clone)]
pub struct WorkspaceStarted(pub WorkspaceLifecyclePayload);

#[derive(Message, Debug, Clone)]
pub struct SessionStarted(pub SessionStartedPayload);

#[derive(Message, Debug, Clone)]
pub struct PhaseChanged(pub TurnAdvancePayload);

#[derive(Message, Debug, Clone)]
pub struct TurnStarted(pub TurnAdvancePayload);

#[derive(Message, Debug, Clone)]
pub struct KeeperUnavailable(pub KeeperUnavailablePayload);

// ─── Phase 2: Intervention + Actor Events ────

// Fields populated by serde deserialization; read only in wasm32 DOM code.
#[allow(dead_code)]
#[derive(Debug, Clone, Deserialize)]
pub struct InterventionPayload {
    pub intervention_type: String,
    #[serde(default)]
    pub target: String,
    #[serde(default)]
    pub description: String,
}

/// Nested actor data sent by the server inside actor lifecycle events.
/// All fields use `#[serde(default)]` for graceful degradation when the
/// server omits them (e.g. actor.delete only sends actor_id).
#[derive(Debug, Clone, Default, Deserialize)]
pub struct ActorData {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub role: String,
    #[serde(default)]
    pub archetype: String,
    #[serde(default)]
    pub persona: String,
    #[serde(default)]
    pub hp: Option<i32>,
    #[serde(default)]
    pub max_hp: Option<i32>,
    #[serde(default)]
    pub alive: Option<bool>,
    #[serde(default)]
    pub traits: Vec<String>,
    #[serde(default)]
    pub skills: Vec<String>,
    #[serde(default)]
    pub inventory: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ActorLifecyclePayload {
    pub actor_id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub class: String,
    #[serde(default)]
    pub keeper: String,
    /// Server sends nested actor object with hp, max_hp, traits, etc.
    #[serde(default)]
    pub actor: Option<ActorData>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WorkspaceEndedPayload {
    pub workspace_id: String,
    #[serde(default)]
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub reason: String,
}

// Fields populated by serde deserialization; read only in wasm32 DOM code.
#[allow(dead_code)]
#[derive(Debug, Clone, Deserialize)]
pub struct TurnActionResolvedPayload {
    #[serde(default)]
    pub turn: u32,
    pub actor_id: String,
    pub action: String,
    pub result: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CombatAttackPayload {
    #[serde(default)]
    pub turn: u32,
    #[serde(default)]
    pub actor_id: String,
    #[serde(default)]
    pub action: String,
    #[serde(default)]
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub target_id: String,
    #[serde(default)]
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub skill: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CombatDefensePayload {
    #[serde(default)]
    pub turn: u32,
    #[serde(default)]
    pub actor_id: String,
    #[serde(default)]
    pub method: String,
    #[serde(default)]
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub source_actor_id: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SessionOutcomePayload {
    pub outcome: String,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub outcome_source: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub turn: u32,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SceneTransitionPayload {
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub from_scene: String,
    pub to_scene: String,
    #[serde(default)]
    #[allow(dead_code)] // read only in wasm32 DOM code
    pub description: String,
}

#[derive(Message, Debug, Clone)]
pub struct InterventionSubmitted(pub InterventionPayload);

#[derive(Message, Debug, Clone)]
pub struct InterventionApplied(pub InterventionPayload);

#[derive(Message, Debug, Clone)]
pub struct ActorSpawned(pub ActorLifecyclePayload);

#[derive(Message, Debug, Clone)]
pub struct ActorDeleted(pub ActorLifecyclePayload);

#[derive(Message, Debug, Clone)]
pub struct ActorClaimed(pub ActorLifecyclePayload);

#[derive(Message, Debug, Clone)]
pub struct ActorReleased(pub ActorLifecyclePayload);

#[derive(Message, Debug, Clone)]
pub struct ActorUpdated(pub ActorLifecyclePayload);

#[derive(Message, Debug, Clone)]
pub struct WorkspaceEnded(pub WorkspaceEndedPayload);

#[derive(Message, Debug, Clone)]
pub struct TurnActionResolved(pub TurnActionResolvedPayload);

#[derive(Message, Debug, Clone)]
pub struct CombatAttack(pub CombatAttackPayload);

#[derive(Message, Debug, Clone)]
pub struct CombatDefense(pub CombatDefensePayload);

#[derive(Message, Debug, Clone)]
pub struct SessionOutcome(pub SessionOutcomePayload);

#[derive(Message, Debug, Clone)]
pub struct SceneTransitioned(pub SceneTransitionPayload);
