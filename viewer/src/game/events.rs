use bevy::prelude::*;
use serde::Deserialize;

// ─── SSE Payload Types ────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct DiceRollPayload {
    #[allow(dead_code)]
    pub turn: u32,
    pub character: String,
    pub action: String,
    pub d20: i32,
    pub bonus: i32,
    pub total: i32,
    pub dc: i32,
    pub result: String,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct HpChangePayload {
    pub target: String,
    pub amount: i32,
    pub remaining_hp: i32,
    #[allow(dead_code)]
    pub source: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NarrativePayload {
    pub text: String,
    pub phase: String,
    #[serde(default)]
    pub speaker: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AreaMovePayload {
    pub character: String,
    #[allow(dead_code)]
    pub from_area: String,
    pub to_area: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TurnAdvancePayload {
    pub turn: u32,
    pub phase: String,
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
    #[allow(dead_code)]
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
    pub actor_id: String,
    #[serde(default)]
    pub keeper: String,
    #[serde(default)]
    #[allow(dead_code)]
    pub role: String,
    #[serde(default)]
    #[allow(dead_code)]
    pub reason: String,
    #[serde(default)]
    pub room_status: String,
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
