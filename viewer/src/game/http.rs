use std::sync::{Arc, Mutex};

use bevy::prelude::*;
use serde::Deserialize;
use serde_json::Value;
use wasm_bindgen::prelude::*;
use wasm_bindgen_futures::JsFuture;

use crate::config;
use crate::game::components::{Actor, Stats};
use crate::game::state::{MapState, RoomState, TurnPhase, TurnProgressState};

// ─── Expected API Response Types ─────────────

#[derive(Debug, Clone, Deserialize)]
pub struct RoomResponse {
    pub id: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub turn: u32,
    #[serde(default)]
    pub phase: String,
    #[serde(default)]
    pub current_scenario: String,
    #[serde(default)]
    pub current_node: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StatsData {
    #[serde(default)]
    pub atk: i32,
    #[serde(default)]
    pub def: i32,
    #[serde(default = "default_int_field")]
    pub int: i32,
    #[serde(default)]
    pub luck: i32,
}

fn default_int_field() -> i32 {
    10
}

#[derive(Debug, Clone, Deserialize)]
pub struct CharacterData {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub class: String,
    #[serde(default = "default_hp")]
    pub hp: i32,
    #[serde(default = "default_hp")]
    pub max_hp: i32,
    #[serde(default)]
    pub stats: Option<StatsData>,
    #[serde(default = "default_area")]
    pub area: String,
    #[serde(default)]
    pub is_dead: bool,
    #[serde(default)]
    pub inventory: Vec<String>,
    #[serde(default)]
    pub buffs: Vec<String>,
    #[serde(default)]
    pub debuffs: Vec<String>,
}

fn default_hp() -> i32 {
    20
}

fn default_area() -> String {
    "A".to_string()
}

#[derive(Debug, Clone, Deserialize)]
pub struct GameStateResponse {
    #[serde(default)]
    pub room: Option<RoomResponse>,
    #[serde(default)]
    pub characters: Vec<CharacterData>,
    #[serde(default)]
    pub current_area: String,
    #[serde(default)]
    pub area_label: String,
}

// ─── Shared Buffer Resource ──────────────────

/// Holds the async fetch result. The startup system fires the fetch,
/// and an update system drains it once the response arrives.
#[derive(Resource)]
pub struct InitialStateBuffer {
    data: Arc<Mutex<Option<GameStateResponse>>>,
    consumed: bool,
}

/// Tracks the currently active TRPG room for runtime room switching.
#[derive(Resource, Default)]
pub struct ActiveTrpgRoom {
    pub room_id: String,
}

fn queue_initial_state_fetch(commands: &mut Commands) {
    let buffer: Arc<Mutex<Option<GameStateResponse>>> = Arc::new(Mutex::new(None));
    let shared = buffer.clone();

    // Fire async fetch on the browser event loop
    wasm_bindgen_futures::spawn_local(async move {
        match fetch_game_state().await {
            Ok(state) => {
                if let Ok(mut buf) = shared.lock() {
                    *buf = Some(state);
                }
                log::info!("Initial game state loaded from engine");
            }
            Err(e) => {
                log::warn!("Engine not available, using mock data: {:?}", e);
                if let Ok(mut buf) = shared.lock() {
                    *buf = Some(mock_game_state());
                }
            }
        }
    });

    commands.insert_resource(InitialStateBuffer {
        data: buffer,
        consumed: false,
    });
}

// ─── Systems ─────────────────────────────────

/// Startup system: fires async HTTP fetch for initial game state.
pub fn fetch_initial_state(
    mut commands: Commands,
    mut active_room: ResMut<ActiveTrpgRoom>,
) {
    active_room.room_id = config::current_room_id();
    queue_initial_state_fetch(&mut commands);
}

/// Detects TRPG room changes at runtime and reloads state for the new room.
pub fn refresh_state_on_room_change(
    mut commands: Commands,
    mut active_room: ResMut<ActiveTrpgRoom>,
    actors: Query<Entity, With<Actor>>,
    mut room_state: ResMut<RoomState>,
    mut map_state: ResMut<MapState>,
    mut turn_progress: ResMut<TurnProgressState>,
) {
    let current_room = config::current_room_id();
    if active_room.room_id == current_room {
        return;
    }

    active_room.room_id = current_room.clone();

    for entity in &actors {
        commands.entity(entity).despawn();
    }

    *room_state = RoomState::default();
    room_state.id = current_room.clone();
    *map_state = MapState::default();
    *turn_progress = TurnProgressState::default();
    turn_progress.room_status = "loading".to_string();

    queue_initial_state_fetch(&mut commands);
    log::info!("TRPG room changed — reloading state for room {}", current_room);
}

/// Update system: polls the buffer each frame. Once data arrives,
/// populates RoomState, MapState, and spawns Actor entities.
pub fn apply_initial_state(
    mut commands: Commands,
    mut buffer: ResMut<InitialStateBuffer>,
    mut room_state: ResMut<RoomState>,
    mut map_state: ResMut<MapState>,
    mut turn_progress: ResMut<TurnProgressState>,
) {
    if buffer.consumed {
        return;
    }

    let state = {
        let Ok(mut buf) = buffer.data.lock() else {
            return;
        };
        buf.take()
    };

    let Some(state) = state else {
        return;
    };

    let actor_ids: Vec<String> = state
        .characters
        .iter()
        .map(|ch| ch.id.clone())
        .collect();

    // Apply room state
    if let Some(room) = state.room {
        room_state.id = room.id;
        room_state.status = room.status;
        room_state.turn = room.turn;
        room_state.phase = TurnPhase::from_str(&room.phase);
        room_state.current_scenario = room.current_scenario;
        room_state.current_node = room.current_node;
    }

    turn_progress.room_status = room_state.status.clone();
    turn_progress.turn = room_state.turn;
    turn_progress.phase = room_state.phase.as_str().to_string();
    turn_progress.player_order = actor_ids
        .iter()
        .filter(|id| id.as_str() != "dm")
        .cloned()
        .collect();
    let player_order = turn_progress.player_order.clone();
    turn_progress.actor_order.clear();
    turn_progress.actor_order.push("dm".to_string());
    for actor_id in &player_order {
        if actor_id != "dm" && !turn_progress.actor_order.iter().any(|id| id == actor_id) {
            turn_progress.actor_order.push(actor_id.clone());
        }
    }
    turn_progress.actor_states.clear();
    let actor_order = turn_progress.actor_order.clone();
    for actor_id in &actor_order {
        turn_progress
            .actor_states
            .insert(actor_id.clone(), "pending".to_string());
    }
    turn_progress.current_actor.clear();
    turn_progress.next_actor.clear();
    turn_progress.last_actor.clear();
    turn_progress.last_result.clear();

    // Apply map state
    if !state.current_area.is_empty() {
        map_state.current_area = state.current_area;
    }
    if !state.area_label.is_empty() {
        map_state.area_label = state.area_label;
    }

    // Spawn actor entities
    for ch in state.characters {
        let stats = ch
            .stats
            .map(|s| Stats {
                atk: s.atk,
                def: s.def,
                int: s.int,
                luck: s.luck,
            })
            .unwrap_or(Stats {
                atk: 10,
                def: 10,
                int: 10,
                luck: 10,
            });

        commands.spawn(Actor {
            id: ch.id,
            name: ch.name,
            class: ch.class,
            hp: ch.hp,
            max_hp: ch.max_hp,
            stats,
            area: ch.area,
            is_dead: ch.is_dead,
            inventory: ch.inventory,
            buffs: ch.buffs,
            debuffs: ch.debuffs,
        });
    }

    buffer.consumed = true;
    log::info!("Initial game state applied to ECS");
}

// ─── Async Fetch ─────────────────────────────

async fn fetch_game_state() -> Result<GameStateResponse, JsValue> {
    let url = config::trpg_state_url();

    let opts = web_sys::RequestInit::new();
    opts.set_method("GET");
    opts.set_mode(web_sys::RequestMode::Cors);

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    request.headers().set("Accept", "application/json")?;

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;

    if !resp.ok() {
        return Err(JsValue::from_str(&format!("HTTP {}", resp.status())));
    }

    let json = JsFuture::from(resp.json()?).await?;
    let root: Value = serde_wasm_bindgen::from_value(json)
        .map_err(|e| JsValue::from_str(&format!("json conversion error: {}", e)))?;

    normalize_state_response(root).map_err(|e| JsValue::from_str(&format!("parse error: {}", e)))
}

fn normalize_state_response(root: Value) -> Result<GameStateResponse, String> {
    if root.get("room").is_some() {
        return serde_json::from_value(root).map_err(|e| e.to_string());
    }

    if root.get("state").is_some() {
        return Ok(parse_masc_state_response(&root));
    }

    Err("unsupported state payload shape".to_string())
}

fn parse_masc_state_response(root: &Value) -> GameStateResponse {
    let state = root.get("state").unwrap_or(&Value::Null);

    let room_id = root
        .get("room_id")
        .and_then(Value::as_str)
        .unwrap_or(config::DEFAULT_ROOM_ID)
        .to_string();

    let turn = state.get("turn").and_then(Value::as_u64).unwrap_or(1) as u32;
    let phase = state
        .get("phase")
        .and_then(Value::as_str)
        .unwrap_or("dm_narration")
        .to_string();

    let current_area = state
        .get("current_area")
        .and_then(Value::as_str)
        .unwrap_or("A")
        .to_string();
    let area_label = state
        .get("area_label")
        .and_then(Value::as_str)
        .unwrap_or("미상 지역")
        .to_string();

    let mut characters = state
        .get("characters")
        .cloned()
        .and_then(|v| serde_json::from_value::<Vec<CharacterData>>(v).ok())
        .unwrap_or_default();

    if characters.is_empty() {
        characters = mock_game_state().characters;
    }

    GameStateResponse {
        room: Some(RoomResponse {
            id: room_id,
            status: state
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("active")
                .to_string(),
            turn,
            phase,
            current_scenario: state
                .get("current_scenario")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            current_node: state
                .get("current_node")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        }),
        characters,
        current_area,
        area_label,
    }
}

// ─── Mock Data ───────────────────────────────

/// Fallback data when the engine is not running.
/// Matches the 4-character party from scenarios.json.
fn mock_game_state() -> GameStateResponse {
    GameStateResponse {
        room: Some(RoomResponse {
            id: "default".to_string(),
            status: "active".to_string(),
            turn: 1,
            phase: "dm_narration".to_string(),
            current_scenario: "prologue".to_string(),
            current_node: "tavern_entrance".to_string(),
        }),
        characters: vec![
            CharacterData {
                id: "grimja".to_string(),
                name: "그림자".to_string(),
                class: "fighter".to_string(),
                hp: 28,
                max_hp: 28,
                stats: Some(StatsData {
                    atk: 16,
                    def: 14,
                    int: 8,
                    luck: 10,
                }),
                area: "A".to_string(),
                is_dead: false,
                inventory: vec![],
                buffs: vec![],
                debuffs: vec![],
            },
            CharacterData {
                id: "luna".to_string(),
                name: "루나".to_string(),
                class: "wizard".to_string(),
                hp: 18,
                max_hp: 18,
                stats: Some(StatsData {
                    atk: 8,
                    def: 10,
                    int: 18,
                    luck: 12,
                }),
                area: "B".to_string(),
                is_dead: false,
                inventory: vec![],
                buffs: vec![],
                debuffs: vec![],
            },
            CharacterData {
                id: "songarak".to_string(),
                name: "손가락".to_string(),
                class: "rogue".to_string(),
                hp: 22,
                max_hp: 22,
                stats: Some(StatsData {
                    atk: 12,
                    def: 12,
                    int: 14,
                    luck: 16,
                }),
                area: "C".to_string(),
                is_dead: false,
                inventory: vec![],
                buffs: vec![],
                debuffs: vec![],
            },
            CharacterData {
                id: "miso".to_string(),
                name: "미소".to_string(),
                class: "cleric".to_string(),
                hp: 24,
                max_hp: 24,
                stats: Some(StatsData {
                    atk: 10,
                    def: 12,
                    int: 16,
                    luck: 14,
                }),
                area: "D".to_string(),
                is_dead: false,
                inventory: vec![],
                buffs: vec![],
                debuffs: vec![],
            },
        ],
        current_area: "A".to_string(),
        area_label: "폐허의 입구".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn normalize_legacy_shape() {
        let root = json!({
            "room": {
                "id": "default",
                "status": "active",
                "turn": 2,
                "phase": "player_action",
                "current_scenario": "prologue",
                "current_node": "gate"
            },
            "characters": [],
            "current_area": "A",
            "area_label": "폐허의 입구"
        });

        let parsed = normalize_state_response(root).expect("legacy parse should succeed");
        assert_eq!(parsed.room.as_ref().map(|r| r.turn), Some(2));
        assert_eq!(parsed.current_area, "A");
    }

    #[test]
    fn normalize_masc_shape_uses_defaults_and_fallback_party() {
        let root = json!({
            "ok": true,
            "room_id": "default",
            "state": {
                "turn": 5,
                "phase": "dm_narration",
                "current_area": "C"
            }
        });

        let parsed = normalize_state_response(root).expect("masc parse should succeed");
        assert_eq!(parsed.room.as_ref().map(|r| r.turn), Some(5));
        assert_eq!(parsed.current_area, "C");
        assert!(!parsed.characters.is_empty(), "fallback party should exist");
    }
}
