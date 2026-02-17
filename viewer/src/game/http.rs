use std::sync::{Arc, Mutex};

use bevy::prelude::*;
use serde::Deserialize;
use serde_json::Value;
use wasm_bindgen::prelude::*;
use wasm_bindgen_futures::JsFuture;

use crate::config;
use crate::game::components::{Actor, Condition, Equipment, Skill, Stats};
use crate::game::state::{ConnectionStatus, MapState, RoomState, TurnPhase, TurnProgressState};

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
pub struct SkillData {
    pub name: String,
    #[serde(default = "default_skill_level")]
    pub level: i32,
}

fn default_skill_level() -> i32 {
    10
}

#[derive(Debug, Clone, Deserialize)]
pub struct ConditionData {
    pub name: String,
    #[serde(default)]
    pub remaining_turns: Option<i32>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct EquipmentData {
    pub slot: String,
    pub name: String,
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
    pub mp: i32,
    #[serde(default)]
    pub max_mp: i32,
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
    #[serde(default)]
    pub skills: Vec<SkillData>,
    #[serde(default)]
    pub conditions: Vec<ConditionData>,
    #[serde(default)]
    pub equipment: Vec<EquipmentData>,
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
    pub room_rev: u32,
}

fn normalize_room_status(raw: &str) -> String {
    raw.trim().to_ascii_lowercase()
}

fn room_requires_new_game(raw_status: &str) -> bool {
    matches!(
        normalize_room_status(raw_status).as_str(),
        "" | "idle" | "lobby" | "ended" | "unavailable"
    )
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
                log::warn!("Engine not available, using unavailable state: {:?}", e);
                if let Ok(mut buf) = shared.lock() {
                    *buf = Some(unavailable_game_state(&config::current_room_id()));
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
    mut connection: ResMut<ConnectionStatus>,
) {
    active_room.room_id = config::current_room_id();
    active_room.room_rev = config::current_room_revision();
    *connection = ConnectionStatus::Connecting;
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
    mut connection: ResMut<ConnectionStatus>,
) {
    let current_room = config::current_room_id();
    let current_room_rev = config::current_room_revision();
    if active_room.room_id == current_room && active_room.room_rev == current_room_rev {
        return;
    }

    active_room.room_id = current_room.clone();
    active_room.room_rev = current_room_rev;

    for entity in &actors {
        commands.entity(entity).despawn();
    }

    *room_state = RoomState::default();
    room_state.id = current_room.clone();
    *map_state = MapState::default();
    *turn_progress = TurnProgressState::default();
    turn_progress.room_status = "loading".to_string();
    *connection = ConnectionStatus::Connecting;

    queue_initial_state_fetch(&mut commands);
    log::info!(
        "TRPG room changed — reloading state for room {} (rev {})",
        current_room,
        current_room_rev
    );
}

/// Update system: polls the buffer each frame. Once data arrives,
/// populates RoomState, MapState, and spawns Actor entities.
pub fn apply_initial_state(
    mut commands: Commands,
    mut buffer: ResMut<InitialStateBuffer>,
    actors: Query<Entity, With<Actor>>,
    mut room_state: ResMut<RoomState>,
    mut map_state: ResMut<MapState>,
    mut turn_progress: ResMut<TurnProgressState>,
    mut connection: ResMut<ConnectionStatus>,
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
    let state_unavailable = state
        .room
        .as_ref()
        .map(|room| room.status.trim() == "unavailable")
        .unwrap_or(false);

    let actor_ids: Vec<String> = state
        .characters
        .iter()
        .map(|ch| ch.id.clone())
        .collect();

    for entity in &actors {
        commands.entity(entity).despawn();
    }

    // Apply room state
    if let Some(room) = &state.room {
        room_state.id = room.id.clone();
        room_state.status = room.status.clone();
        room_state.turn = room.turn;
        room_state.phase = TurnPhase::from_str(&room.phase);
        room_state.current_scenario = room.current_scenario.clone();
        room_state.current_node = room.current_node.clone();
    }

    if state_unavailable {
        *connection = ConnectionStatus::Disconnected;
    } else {
        *connection = ConnectionStatus::Connected;
    }

    // Rooms in terminal/empty states should open the new-game flow instead of
    // replaying stale entities. Paused/running rooms are resumable and keep state.
    if room_requires_new_game(&room_state.status) {
        turn_progress.room_status = room_state.status.clone();
        turn_progress.turn = room_state.turn;
        turn_progress.phase = room_state.phase.as_str().to_string();
        turn_progress.player_order.clear();
        turn_progress.actor_order.clear();
        turn_progress.actor_states.clear();
        turn_progress.current_actor.clear();
        turn_progress.next_actor.clear();
        turn_progress.last_actor.clear();
        turn_progress.last_result.clear();
        *map_state = MapState::default();
        buffer.consumed = true;

        prompt_new_game_for_inactive_room(room_state.status.trim());
        log::info!(
            "Room '{}' is not resumable (status: '{}') — skipping actor spawn, showing new-game panel",
            room_state.id,
            room_state.status,
        );
        return;
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

        let skills: Vec<Skill> = ch
            .skills
            .into_iter()
            .map(|s| Skill {
                name: s.name,
                level: s.level,
            })
            .collect();

        let conditions: Vec<Condition> = ch
            .conditions
            .into_iter()
            .map(|c| Condition {
                name: c.name,
                remaining_turns: c.remaining_turns,
            })
            .collect();

        let equipment: Vec<Equipment> = ch
            .equipment
            .into_iter()
            .map(|e| Equipment {
                slot: e.slot,
                name: e.name,
            })
            .collect();

        commands.spawn(Actor {
            id: ch.id,
            name: ch.name,
            class: ch.class,
            hp: ch.hp,
            max_hp: ch.max_hp,
            mp: ch.mp,
            max_mp: ch.max_mp,
            stats,
            area: ch.area,
            is_dead: ch.is_dead,
            inventory: ch.inventory,
            buffs: ch.buffs,
            debuffs: ch.debuffs,
            skills,
            conditions,
            equipment,
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

    let turn = state.get("turn").and_then(Value::as_u64).unwrap_or(0) as u32;
    let phase = state
        .get("phase")
        .and_then(Value::as_str)
        .unwrap_or("dm_narration")
        .to_string();

    let current_area = state
        .get("current_area")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let area_label = state
        .get("area_label")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();

    let characters = state
        .get("characters")
        .cloned()
        .and_then(|v| serde_json::from_value::<Vec<CharacterData>>(v).ok())
        .filter(|rows| !rows.is_empty())
        .unwrap_or_else(|| parse_party_characters(state));

    GameStateResponse {
        room: Some(RoomResponse {
            id: room_id,
            status: state
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("idle")
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

fn parse_party_characters(state: &Value) -> Vec<CharacterData> {
    let Some(party) = state.get("party").and_then(Value::as_object) else {
        return Vec::new();
    };

    party
        .iter()
        .map(|(actor_id, info)| {
            let name = info
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or(actor_id)
                .to_string();
            let class = info
                .get("class")
                .and_then(Value::as_str)
                .or_else(|| info.get("role").and_then(Value::as_str))
                .or_else(|| info.get("archetype").and_then(Value::as_str))
                .unwrap_or("")
                .to_string();
            let hp = info.get("hp").and_then(Value::as_i64).unwrap_or(20) as i32;
            let max_hp = info
                .get("max_hp")
                .and_then(Value::as_i64)
                .unwrap_or(i64::from(hp.max(1))) as i32;
            let area = info
                .get("position")
                .and_then(Value::as_str)
                .or_else(|| info.get("area").and_then(Value::as_str))
                .unwrap_or("A")
                .to_string();
            let is_dead = info
                .get("alive")
                .and_then(Value::as_bool)
                .map(|alive| !alive)
                .unwrap_or_else(|| hp <= 0);
            let inventory = info
                .get("inventory")
                .and_then(Value::as_array)
                .map(|rows| {
                    rows.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_string)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let buffs = info
                .get("buffs")
                .and_then(Value::as_array)
                .map(|rows| {
                    rows.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_string)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let debuffs = info
                .get("debuffs")
                .and_then(Value::as_array)
                .map(|rows| {
                    rows.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_string)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let stats = info
                .get("stats")
                .cloned()
                .and_then(|v| serde_json::from_value::<StatsData>(v).ok());

            CharacterData {
                id: actor_id.to_string(),
                name,
                class,
                hp,
                max_hp,
                mp: 0,
                max_mp: 0,
                stats,
                area,
                is_dead,
                inventory,
                buffs,
                debuffs,
                skills: vec![],
                conditions: vec![],
                equipment: vec![],
            }
        })
        .collect()
}

/// When the fetched room is not resumable, auto-show the new-game panel
/// and pre-fill a fresh room ID so the user can start a new session.
fn prompt_new_game_for_inactive_room(room_status: &str) {
    let _ = room_status;

    #[cfg(target_arch = "wasm32")]
    {
        let Some(document) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        // Show the new-game panel
        if let Some(panel) = document.get_element_by_id("new-game-panel") {
            if let Some(html_el) = panel.dyn_ref::<web_sys::HtmlElement>() {
                let _ = html_el.style().set_property("display", "flex");
            }
        }

        // Pre-populate room ID input with a fresh generated ID
        if let Some(input) = document
            .get_element_by_id("new-game-room-id")
            .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
        {
            if input.value().trim().is_empty() {
                let ts = js_sys::Date::now() as i64;
                let rand = (js_sys::Math::random() * 1000.0).floor() as i64;
                input.set_value(&format!("adventure-{}-{:03}", ts, rand));
            }
        }

        // Set a status message appropriate to the room state
        if let Some(el) = document.get_element_by_id("new-game-status") {
            let msg = match normalize_room_status(room_status).as_str() {
                "ended" => "이 게임은 종료되었습니다. 새 게임을 시작하세요.",
                "unavailable" => "엔진에 연결할 수 없습니다. 새 게임을 시작하면 재연결을 시도합니다.",
                _ => "진행 중인 게임이 없습니다. 새 게임을 시작하세요.",
            };
            el.set_inner_html(msg);
        }
    }
}

fn unavailable_game_state(room_id: &str) -> GameStateResponse {
    GameStateResponse {
        room: Some(RoomResponse {
            id: room_id.to_string(),
            status: "unavailable".to_string(),
            turn: 0,
            phase: "dm_narration".to_string(),
            current_scenario: "".to_string(),
            current_node: "".to_string(),
        }),
        characters: Vec::new(),
        current_area: "".to_string(),
        area_label: "".to_string(),
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
    fn normalize_masc_shape_uses_defaults_without_fallback_party() {
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
        assert!(parsed.characters.is_empty(), "no fallback party should be injected");
    }

    #[test]
    fn normalize_masc_shape_reads_party_as_characters() {
        let root = json!({
            "ok": true,
            "room_id": "default",
            "state": {
                "turn": 3,
                "phase": "round",
                "party": {
                    "grimja": {
                        "name": "그림자",
                        "role": "fighter",
                        "hp": 28,
                        "max_hp": 30,
                        "position": "C",
                        "alive": true
                    }
                }
            }
        });

        let parsed = normalize_state_response(root).expect("masc parse should succeed");
        assert_eq!(parsed.characters.len(), 1);
        assert_eq!(parsed.characters[0].id, "grimja");
        assert_eq!(parsed.characters[0].name, "그림자");
        assert_eq!(parsed.characters[0].class, "fighter");
        assert_eq!(parsed.characters[0].hp, 28);
    }

    #[test]
    fn ended_room_is_not_active() {
        let root = json!({
            "room": {
                "id": "adventure-123",
                "status": "ended",
                "turn": 8,
                "phase": "transition",
                "current_scenario": "epilogue",
                "current_node": "end"
            },
            "characters": [
                { "id": "warrior-1", "name": "Kael" }
            ],
            "current_area": "D",
            "area_label": "왕좌의 간"
        });

        let parsed = normalize_state_response(root).expect("ended room parse should succeed");
        let status = parsed.room.as_ref().map(|r| r.status.as_str()).unwrap_or("");
        assert_ne!(status, "active", "ended room should not be treated as active");
        assert_eq!(status, "ended");
        assert_eq!(parsed.characters.len(), 1, "characters still parsed even for ended rooms");
    }

    #[test]
    fn idle_room_is_not_active() {
        let root = json!({
            "room": {
                "id": "default",
                "status": "idle",
                "turn": 0,
                "phase": "dm_narration"
            },
            "characters": [],
            "current_area": "",
            "area_label": ""
        });

        let parsed = normalize_state_response(root).expect("idle room parse should succeed");
        let status = parsed.room.as_ref().map(|r| r.status.as_str()).unwrap_or("");
        assert_ne!(status, "active");
        assert!(parsed.characters.is_empty());
    }

    #[test]
    fn unavailable_game_state_has_correct_shape() {
        let state = unavailable_game_state("test-room");
        let room = state.room.as_ref().expect("room should be present");
        assert_eq!(room.id, "test-room");
        assert_eq!(room.status, "unavailable");
        assert!(state.characters.is_empty());
    }

    #[test]
    fn paused_room_is_resumable() {
        assert!(!room_requires_new_game("paused"));
    }

    #[test]
    fn ended_room_requires_new_game() {
        assert!(room_requires_new_game("ended"));
    }

    #[test]
    fn normalize_room_status_is_case_insensitive() {
        assert_eq!(normalize_room_status("  AcTiVe "), "active");
    }
}
