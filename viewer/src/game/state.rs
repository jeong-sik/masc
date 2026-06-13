use bevy::prelude::*;
use std::collections::BTreeMap;

/// Turn phases as defined in engine.json.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum TurnPhase {
    #[default]
    DmNarration,
    PartyDiscussion,
    ActionDeclaration,
    DiceResolution,
    OutcomeNarration,
    StateUpdate,
    Transition,
}

impl TurnPhase {
    pub fn from_str(s: &str) -> Self {
        match s {
            "dm_narration" | "briefing" => Self::DmNarration,
            "party_discussion" | "round" | "discuss" => Self::PartyDiscussion,
            "action_declaration" | "action" => Self::ActionDeclaration,
            "dice_resolution" | "dice" => Self::DiceResolution,
            "outcome_narration" | "outcome" => Self::OutcomeNarration,
            "state_update" => Self::StateUpdate,
            "transition" => Self::Transition,
            other => {
                if !other.is_empty() {
                    log::warn!("Unknown TurnPhase string: {:?}, defaulting to DmNarration", other);
                }
                Self::DmNarration
            }
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::DmNarration => "dm_narration",
            Self::PartyDiscussion => "party_discussion",
            Self::ActionDeclaration => "action_declaration",
            Self::DiceResolution => "dice_resolution",
            Self::OutcomeNarration => "outcome_narration",
            Self::StateUpdate => "state_update",
            Self::Transition => "transition",
        }
    }
}

/// Global game workspace state.
#[derive(Resource, Debug, Default)]
pub struct WorkspaceState {
    pub id: String,
    pub status: String,
    pub turn: u32,
    pub phase: TurnPhase,
    pub current_scenario: String,
    pub current_node: String,
}

/// Current map/area state.
#[derive(Resource, Debug, Default)]
pub struct MapState {
    pub current_area: String,
    pub area_label: String,
}

/// Current weather and mood overlay state.
#[derive(Resource, Debug, Default)]
pub struct OverlayState {
    pub weather: String,
    pub mood: String,
}

/// Connection status for the SSE stream.
#[derive(Resource, Debug, Default)]
pub enum ConnectionStatus {
    #[default]
    Disconnected,
    Connecting,
    Connected,
    /// Reconnecting after a lost connection. (current_attempt, max_attempts)
    #[allow(dead_code)] // constructed only in wasm32 reconnect logic
    Reconnecting(u32, u32),
    /// All retry attempts exhausted.
    #[allow(dead_code)] // constructed only in wasm32 reconnect logic
    Failed,
}

/// Runtime progress derived from TRPG stream events.
#[derive(Resource, Debug, Default)]
pub struct TurnProgressState {
    pub workspace_status: String,
    pub turn: u32,
    pub phase: String,
    pub dm_keeper: String,
    pub player_order: Vec<String>,
    pub actor_order: Vec<String>,
    pub actor_states: BTreeMap<String, String>,
    pub actor_reasons: BTreeMap<String, String>,
    pub current_actor: String,
    pub next_actor: String,
    pub last_actor: String,
    pub last_result: String,
    pub last_event: String,
}

#[derive(Resource, Debug, Default)]
pub struct ChoiceState {
    pub active: bool,
    pub character: String,
    pub description: String,
    pub options: Vec<String>,
}

#[derive(Resource, Debug, Default)]
pub struct CombatState {
    pub active: bool,
    pub area: String,
    pub enemies: Vec<String>,
}
