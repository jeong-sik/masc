use bevy::prelude::*;
use serde::Deserialize;

/// Stats block for a character — mirrors the TRPG Engine schema.
#[derive(Debug, Clone, Deserialize)]
pub struct Stats {
    pub atk: i32,
    pub def: i32,
    pub int: i32,
    pub luck: i32,
}

/// A single skill with level and optional UI-facing copy.
#[derive(Debug, Clone, Deserialize)]
pub struct Skill {
    pub name: String,
    pub level: i32,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub usage_hint: String,
}

impl Skill {
    /// Modifier derived from proficiency level: (level - 10) / 2, floored.
    pub fn modifier(&self) -> i32 {
        (self.level - 10) / 2
    }
}

/// An active condition affecting the character (e.g. poisoned, stunned).
#[derive(Debug, Clone, Deserialize)]
pub struct Condition {
    pub name: String,
    #[serde(default)]
    pub remaining_turns: Option<i32>,
}

/// A piece of equipped gear.
#[derive(Debug, Clone, Deserialize)]
pub struct Equipment {
    pub slot: String,
    pub name: String,
}

/// Core actor component — represents a party member or NPC on the map.
#[derive(Component, Debug, Clone)]
pub struct Actor {
    pub id: String,
    pub name: String,
    pub class: String,
    pub archetype: String,
    pub persona: String,
    pub traits: Vec<String>,
    pub hp: i32,
    pub max_hp: i32,
    pub mp: i32,
    pub max_mp: i32,
    pub stats: Stats,
    pub area: String,
    pub is_dead: bool,
    pub inventory: Vec<String>,
    pub buffs: Vec<String>,
    pub debuffs: Vec<String>,
    pub skills: Vec<Skill>,
    pub conditions: Vec<Condition>,
    pub equipment: Vec<Equipment>,
    pub keeper: String,
}

/// Marker component for entities rendered as map tokens.
#[derive(Component, Debug)]
pub struct MapToken;

/// HP bar sprite attached as a child entity of each Actor.
#[derive(Component, Debug)]
pub struct HpBarSprite {
    pub max_width: f32,
}

/// Floating damage/heal text that drifts upward and fades.
#[derive(Component, Debug)]
pub struct FloatingText {
    pub timer: Timer,
    pub velocity: Vec2,
}

/// Marker for the 2D camera.
#[derive(Component, Debug)]
pub struct GameCamera;

/// Marker for the map background sprite (needed for OnExit despawn).
#[derive(Component, Debug)]
pub struct MapBackground;

/// Marker for the full-screen weather overlay sprite (z = -9.0).
#[derive(Component, Debug)]
pub struct WeatherOverlay;

/// Marker for the full-screen mood overlay sprite (z = -8.0).
#[derive(Component, Debug)]
pub struct MoodOverlay;
