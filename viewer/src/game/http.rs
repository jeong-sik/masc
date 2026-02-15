use std::sync::{Arc, Mutex};

use bevy::prelude::*;
use serde::Deserialize;
use wasm_bindgen::prelude::*;
use wasm_bindgen_futures::JsFuture;

use crate::config;
use crate::game::components::{Actor, Stats};
use crate::game::state::{MapState, RoomState, TurnPhase};

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

// ─── Systems ─────────────────────────────────

/// Startup system: fires async HTTP fetch for initial game state.
pub fn fetch_initial_state(mut commands: Commands) {
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

/// Update system: polls the buffer each frame. Once data arrives,
/// populates RoomState, MapState, and spawns Actor entities.
pub fn apply_initial_state(
    mut commands: Commands,
    mut buffer: ResMut<InitialStateBuffer>,
    mut room_state: ResMut<RoomState>,
    mut map_state: ResMut<MapState>,
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

    // Apply room state
    if let Some(room) = state.room {
        room_state.id = room.id;
        room_state.status = room.status;
        room_state.turn = room.turn;
        room_state.phase = TurnPhase::from_str(&room.phase);
        room_state.current_scenario = room.current_scenario;
        room_state.current_node = room.current_node;
    }

    // Apply map state
    if !state.current_area.is_empty() {
        map_state.current_area = state.current_area;
    }
    if !state.area_label.is_empty() {
        map_state.area_label = state.area_label;
    }

    // Spawn actor entities
    for ch in state.characters {
        let stats = ch.stats.map(|s| Stats {
            atk: s.atk,
            def: s.def,
            int: s.int,
            luck: s.luck,
        }).unwrap_or(Stats { atk: 10, def: 10, int: 10, luck: 10 });

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
    let url = config::trpg_room_url("/state");

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
    let state: GameStateResponse = serde_wasm_bindgen::from_value(json)
        .map_err(|e| JsValue::from_str(&format!("parse error: {}", e)))?;

    Ok(state)
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
                stats: Some(StatsData { atk: 16, def: 14, int: 8, luck: 10 }),
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
                stats: Some(StatsData { atk: 8, def: 10, int: 18, luck: 12 }),
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
                stats: Some(StatsData { atk: 12, def: 12, int: 14, luck: 16 }),
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
                stats: Some(StatsData { atk: 10, def: 12, int: 16, luck: 14 }),
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
