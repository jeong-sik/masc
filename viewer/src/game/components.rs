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

/// Core actor component — represents a party member or NPC on the map.
#[derive(Component, Debug, Clone)]
pub struct Actor {
    pub id: String,
    pub name: String,
    pub class: String,
    pub hp: i32,
    pub max_hp: i32,
    pub stats: Stats,
    pub area: String,
    pub is_dead: bool,
    pub inventory: Vec<String>,
    pub buffs: Vec<String>,
    pub debuffs: Vec<String>,
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
