use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use bevy::prelude::*;
use serde::Deserialize;
use serde_json::Value;
use wasm_bindgen::prelude::*;
use wasm_bindgen_futures::JsFuture;

use crate::config;
use crate::game::components::{Actor, Condition, Equipment, Skill, Stats};
use crate::game::events::*;
use crate::game::state::{
    ConnectionStatus, MapState, TurnPhase, TurnProgressState, WorkspaceState,
};

// ─── Expected API Response Types ─────────────

#[derive(Debug, Clone, Deserialize)]
pub struct WorkspaceResponse {
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
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub usage_hint: String,
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
    #[serde(default)]
    pub archetype: String,
    #[serde(default)]
    pub persona: String,
    #[serde(default)]
    pub traits: Vec<String>,
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
    #[serde(default)]
    pub keeper: String,
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
    pub workspace: Option<WorkspaceResponse>,
    #[serde(default)]
    pub characters: Vec<CharacterData>,
    #[serde(default)]
    pub dm_keeper: String,
    #[serde(default)]
    pub current_area: String,
    #[serde(default)]
    pub area_label: String,
    #[serde(default)]
    pub dice_log: Vec<DiceRollPayload>,
}

// ─── Shared Buffer Resource ──────────────────

/// Holds the async fetch result. The startup system fires the fetch,
/// and an update system drains it once the response arrives.
#[derive(Resource)]
pub struct InitialStateBuffer {
    data: Arc<Mutex<Option<GameStateResponse>>>,
    consumed: bool,
}

/// Tracks the currently active TRPG workspace for runtime workspace switching.
#[derive(Resource, Default)]
pub struct ActiveTrpgWorkspace {
    pub workspace_id: String,
    pub workspace_rev: u32,
}

fn normalize_workspace_status(raw: &str) -> String {
    raw.trim().to_ascii_lowercase()
}

fn workspace_requires_new_game(raw_status: &str) -> bool {
    matches!(
        normalize_workspace_status(raw_status).as_str(),
        "" | "idle" | "ended" | "completed" | "done" | "retired" | "closed" | "unavailable"
    )
}

fn initial_progress_event_type(
    workspace_status: &str,
    state_unavailable: bool,
) -> Option<&'static str> {
    if state_unavailable {
        return None;
    }
    let status = normalize_workspace_status(workspace_status);
    if matches!(
        status.as_str(),
        "ended" | "completed" | "done" | "retired" | "closed"
    ) {
        Some("workspace.ended")
    } else if workspace_requires_new_game(status.as_str()) {
        None
    } else {
        Some("workspace.started")
    }
}

fn should_emit_initial_turn_advanced(
    workspace_turn: u32,
    workspace_status: &str,
    state_unavailable: bool,
) -> bool {
    workspace_turn > 0
        && matches!(
            initial_progress_event_type(workspace_status, state_unavailable),
            Some("workspace.started")
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
                    *buf = Some(unavailable_game_state(&config::current_workspace_id()));
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
    mut active_workspace: ResMut<ActiveTrpgWorkspace>,
    mut connection: ResMut<ConnectionStatus>,
) {
    active_workspace.workspace_id = config::current_workspace_id();
    active_workspace.workspace_rev = config::current_workspace_revision();
    *connection = ConnectionStatus::Connecting;
    queue_initial_state_fetch(&mut commands);
}

/// Detects TRPG workspace changes at runtime and reloads state for the new workspace.
pub fn refresh_state_on_workspace_change(
    mut commands: Commands,
    mut active_workspace: ResMut<ActiveTrpgWorkspace>,
    actors: Query<Entity, With<Actor>>,
    mut workspace_state: ResMut<WorkspaceState>,
    mut map_state: ResMut<MapState>,
    mut turn_progress: ResMut<TurnProgressState>,
    mut connection: ResMut<ConnectionStatus>,
) {
    let current_workspace = config::current_workspace_id();
    let current_workspace_rev = config::current_workspace_revision();
    if active_workspace.workspace_id == current_workspace
        && active_workspace.workspace_rev == current_workspace_rev
    {
        return;
    }

    active_workspace.workspace_id = current_workspace.clone();
    active_workspace.workspace_rev = current_workspace_rev;

    for entity in &actors {
        commands.entity(entity).despawn();
    }

    *workspace_state = WorkspaceState::default();
    workspace_state.id = current_workspace.clone();
    *map_state = MapState::default();
    *turn_progress = TurnProgressState::default();
    turn_progress.workspace_status = "loading".to_string();
    *connection = ConnectionStatus::Connecting;

    queue_initial_state_fetch(&mut commands);
    log::info!(
        "TRPG workspace changed — reloading state for workspace {} (rev {})",
        current_workspace,
        current_workspace_rev
    );
}

/// Update system: polls the buffer each frame. Once data arrives,
/// populates WorkspaceState, MapState, and spawns Actor entities.
#[allow(clippy::too_many_arguments)]
pub fn apply_initial_state(
    mut commands: Commands,
    mut buffer: ResMut<InitialStateBuffer>,
    actors: Query<Entity, With<Actor>>,
    mut workspace_state: ResMut<WorkspaceState>,
    mut map_state: ResMut<MapState>,
    mut turn_progress: ResMut<TurnProgressState>,
    mut connection: ResMut<ConnectionStatus>,
    mut dice_writer: MessageWriter<DiceRolled>,
    mut turn_writer: MessageWriter<TurnAdvanced>,
    mut progress_writer: MessageWriter<TurnProgressUpdated>,
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
        .workspace
        .as_ref()
        .map(|workspace| workspace.status.trim() == "unavailable")
        .unwrap_or(false);

    let actor_ids: Vec<String> = state.characters.iter().map(|ch| ch.id.clone()).collect();
    if let Some(workspace) = &state.workspace {
        if let Some(workspace_event) =
            initial_progress_event_type(&workspace.status, state_unavailable)
        {
            let selected_players = actor_ids
                .iter()
                .filter(|id| id.as_str() != "dm")
                .cloned()
                .collect::<Vec<_>>();
            progress_writer.write(TurnProgressUpdated(TurnProgressPayload {
                event_type: workspace_event.to_string(),
                turn: workspace.turn,
                phase: workspace.phase.clone(),
                workspace_id: workspace.id.clone(),
                actor_id: "".to_string(),
                keeper: "".to_string(),
                role: "".to_string(),
                reason: "".to_string(),
                workspace_status: workspace.status.clone(),
                dm_keeper: "".to_string(),
                selected_player_ids: selected_players,
            }));
            if should_emit_initial_turn_advanced(
                workspace.turn,
                &workspace.status,
                state_unavailable,
            ) {
                turn_writer.write(TurnAdvanced(TurnAdvancePayload {
                    turn: workspace.turn,
                    phase: workspace.phase.clone(),
                    workspace_id: workspace.id.clone(),
                }));
            }
            for roll in &state.dice_log {
                dice_writer.write(DiceRolled(roll.clone()));
            }
        }
    }

    for entity in &actors {
        commands.entity(entity).despawn();
    }

    // Apply workspace state
    if let Some(workspace) = &state.workspace {
        workspace_state.id = workspace.id.clone();
        workspace_state.status = workspace.status.clone();
        workspace_state.turn = workspace.turn;
        workspace_state.phase = TurnPhase::from_str(&workspace.phase);
        workspace_state.current_scenario = workspace.current_scenario.clone();
        workspace_state.current_node = workspace.current_node.clone();
    }

    if state_unavailable {
        *connection = ConnectionStatus::Disconnected;
    } else {
        *connection = ConnectionStatus::Connected;
    }

    // Workspaces in terminal/empty states should open the new-game flow instead of
    // replaying stale entities. Paused/running workspaces are resumable and keep state.
    if workspace_requires_new_game(&workspace_state.status) {
        turn_progress.workspace_status = workspace_state.status.clone();
        turn_progress.turn = workspace_state.turn;
        turn_progress.phase = workspace_state.phase.as_str().to_string();
        turn_progress.player_order.clear();
        turn_progress.actor_order.clear();
        turn_progress.actor_states.clear();
        turn_progress.actor_reasons.clear();
        turn_progress.current_actor.clear();
        turn_progress.next_actor.clear();
        turn_progress.last_actor.clear();
        turn_progress.last_result.clear();
        *map_state = MapState::default();
        buffer.consumed = true;

        prompt_new_game_for_inactive_workspace(workspace_state.status.trim());
        log::info!(
            "Workspace '{}' is not resumable (status: '{}') — skipping actor spawn, showing new-game guidance",
            workspace_state.id,
            workspace_state.status,
        );
        return;
    }

    turn_progress.workspace_status = workspace_state.status.clone();
    turn_progress.turn = workspace_state.turn;
    turn_progress.phase = workspace_state.phase.as_str().to_string();
    if !state.dm_keeper.trim().is_empty() {
        turn_progress.dm_keeper = state.dm_keeper.trim().to_string();
    }
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
    turn_progress.actor_reasons.clear();
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
                description: s.description,
                usage_hint: s.usage_hint,
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
            archetype: ch.archetype,
            persona: ch.persona,
            traits: ch.traits,
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
            keeper: ch.keeper,
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
    config::apply_auth_headers(&request.headers())?;
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
    if root.get("workspace").is_some() {
        let mut parsed: GameStateResponse =
            serde_json::from_value(root.clone()).map_err(|e| e.to_string())?;
        if root.get("state").is_some() {
            let fallback = parse_masc_state_response(&root);
            merge_state_fallback(&mut parsed, &fallback);
        }
        return Ok(parsed);
    }

    if root.get("state").is_some() {
        return Ok(parse_masc_state_response(&root));
    }

    if root.get("dice_log").is_some() || root.get("status").is_some() {
        return Ok(parse_masc_state_response(&root));
    }

    Err("unsupported state payload shape".to_string())
}

fn merge_state_fallback(primary: &mut GameStateResponse, fallback: &GameStateResponse) {
    match (&mut primary.workspace, fallback.workspace.as_ref()) {
        (None, Some(workspace)) => primary.workspace = Some(workspace.clone()),
        (Some(primary_workspace), Some(fallback_workspace)) => {
            if primary_workspace.id.trim().is_empty() && !fallback_workspace.id.trim().is_empty() {
                primary_workspace.id = fallback_workspace.id.clone();
            }
            if primary_workspace.status.trim().is_empty()
                || primary_workspace.status.eq_ignore_ascii_case("unknown")
            {
                primary_workspace.status = fallback_workspace.status.clone();
            }
            if primary_workspace.turn == 0 && fallback_workspace.turn > 0 {
                primary_workspace.turn = fallback_workspace.turn;
            }
            if primary_workspace.phase.trim().is_empty()
                && !fallback_workspace.phase.trim().is_empty()
            {
                primary_workspace.phase = fallback_workspace.phase.clone();
            }
            if primary_workspace.current_scenario.trim().is_empty()
                && !fallback_workspace.current_scenario.trim().is_empty()
            {
                primary_workspace.current_scenario = fallback_workspace.current_scenario.clone();
            }
            if primary_workspace.current_node.trim().is_empty()
                && !fallback_workspace.current_node.trim().is_empty()
            {
                primary_workspace.current_node = fallback_workspace.current_node.clone();
            }
        }
        _ => {}
    }

    if primary.characters.is_empty() && !fallback.characters.is_empty() {
        primary.characters = fallback.characters.clone();
    }
    if primary.dm_keeper.trim().is_empty() && !fallback.dm_keeper.trim().is_empty() {
        primary.dm_keeper = fallback.dm_keeper.clone();
    }
    if primary.current_area.trim().is_empty() && !fallback.current_area.trim().is_empty() {
        primary.current_area = fallback.current_area.clone();
    }
    if primary.area_label.trim().is_empty() && !fallback.area_label.trim().is_empty() {
        primary.area_label = fallback.area_label.clone();
    }
    if primary.dice_log.is_empty() && !fallback.dice_log.is_empty() {
        primary.dice_log = fallback.dice_log.clone();
    }
}

fn parse_masc_state_response(root: &Value) -> GameStateResponse {
    let state = root.get("state").unwrap_or(root);
    let actor_control = parse_actor_control_map(state);

    let workspace_id = root
        .get("workspace_id")
        .or_else(|| state.get("workspace_id"))
        .and_then(Value::as_str)
        .unwrap_or(config::DEFAULT_WORKSPACE_ID)
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

    let mut characters = state
        .get("characters")
        .cloned()
        .and_then(|v| serde_json::from_value::<Vec<CharacterData>>(v).ok())
        .filter(|rows| !rows.is_empty())
        .unwrap_or_else(|| parse_party_characters(state, &actor_control));
    apply_actor_control_to_characters(&mut characters, &actor_control);

    let dm_keeper = state
        .get("dm_keeper")
        .and_then(Value::as_str)
        .or_else(|| {
            state
                .get("dm")
                .and_then(Value::as_object)
                .and_then(|dm| dm.get("keeper_name"))
                .and_then(Value::as_str)
        })
        .or_else(|| actor_control.get("dm").map(|value| value.as_str()))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
        .or_else(|| infer_dm_keeper_from_narration(state))
        .unwrap_or_default();
    let dice_log =
        parse_dice_log(root).unwrap_or_else(|| parse_dice_log(state).unwrap_or_default());

    GameStateResponse {
        workspace: Some(WorkspaceResponse {
            id: workspace_id,
            status: state
                .get("status")
                .or_else(|| root.get("status"))
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| phase.clone()),
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
        dm_keeper,
        current_area,
        area_label,
        dice_log,
    }
}

fn parse_actor_control_map(state: &Value) -> HashMap<String, String> {
    let mut actor_control = state
        .get("actor_control")
        .and_then(Value::as_object)
        .map(|rows| {
            rows.iter()
                .filter_map(|(actor_id, keeper)| {
                    keeper
                        .as_str()
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                        .map(|keeper_name| (actor_id.trim().to_string(), keeper_name.to_string()))
                })
                .collect::<HashMap<_, _>>()
        })
        .unwrap_or_default();

    for (actor_id, keeper_name) in infer_actor_control_from_dice(state) {
        actor_control.entry(actor_id).or_insert(keeper_name);
    }
    for (actor_id, keeper_name) in infer_actor_control_from_narration(state) {
        actor_control.entry(actor_id).or_insert(keeper_name);
    }

    actor_control
}

fn current_turn_marker(state: &Value) -> Option<u32> {
    state
        .get("turn")
        .and_then(Value::as_u64)
        .and_then(|turn| u32::try_from(turn).ok())
        .filter(|turn| *turn > 0)
}

fn entry_turn_matches(entry: &Value, current_turn: u32) -> bool {
    entry
        .get("turn")
        .and_then(Value::as_u64)
        .and_then(|turn| u32::try_from(turn).ok())
        .is_some_and(|turn| turn == current_turn)
}

fn infer_actor_control_from_dice(state: &Value) -> HashMap<String, String> {
    let Some(current_turn) = current_turn_marker(state) else {
        return HashMap::new();
    };
    state
        .get("dice_log")
        .and_then(Value::as_array)
        .map(|entries| {
            entries
                .iter()
                .filter(|entry| entry_turn_matches(entry, current_turn))
                .filter_map(|entry| {
                    let actor_id = entry
                        .get("actor_id")
                        .or_else(|| entry.get("character"))
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .unwrap_or("");
                    let keeper_name = entry
                        .get("keeper")
                        .or_else(|| entry.get("keeper_name"))
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .unwrap_or("");

                    if actor_id.is_empty()
                        || keeper_name.is_empty()
                        || actor_id.eq_ignore_ascii_case("dm")
                    {
                        None
                    } else {
                        Some((actor_id.to_string(), keeper_name.to_string()))
                    }
                })
                .collect::<HashMap<_, _>>()
        })
        .unwrap_or_default()
}

fn infer_actor_control_from_narration(state: &Value) -> HashMap<String, String> {
    let Some(current_turn) = current_turn_marker(state) else {
        return HashMap::new();
    };
    state
        .get("narration_log")
        .and_then(Value::as_array)
        .map(|entries| {
            entries
                .iter()
                .filter(|entry| entry_turn_matches(entry, current_turn))
                .filter_map(|entry| {
                    let actor_id = entry
                        .get("actor_id")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .unwrap_or("");
                    let keeper_name = entry
                        .get("keeper")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .unwrap_or("");

                    if actor_id.is_empty()
                        || keeper_name.is_empty()
                        || actor_id.eq_ignore_ascii_case("dm")
                    {
                        None
                    } else {
                        Some((actor_id.to_string(), keeper_name.to_string()))
                    }
                })
                .collect::<HashMap<_, _>>()
        })
        .unwrap_or_default()
}

fn infer_dm_keeper_from_narration(state: &Value) -> Option<String> {
    let current_turn = current_turn_marker(state);
    state
        .get("narration_log")
        .and_then(Value::as_array)
        .and_then(|entries| {
            entries.iter().rev().find_map(|entry| {
                if let Some(turn) = current_turn {
                    if !entry_turn_matches(entry, turn) {
                        return None;
                    }
                }
                let role = entry.get("role").and_then(Value::as_str).unwrap_or("");
                let actor_id = entry.get("actor_id").and_then(Value::as_str).unwrap_or("");
                if role.eq_ignore_ascii_case("dm") || actor_id.eq_ignore_ascii_case("dm") {
                    entry
                        .get("keeper")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                        .map(ToString::to_string)
                } else {
                    None
                }
            })
        })
}

fn apply_actor_control_to_characters(
    characters: &mut [CharacterData],
    actor_control: &HashMap<String, String>,
) {
    for row in characters.iter_mut() {
        if row.keeper.trim().is_empty() {
            if let Some(keeper) = actor_control.get(&row.id) {
                row.keeper = keeper.clone();
            }
        }
    }
}

fn parse_dice_log(root: &Value) -> Option<Vec<DiceRollPayload>> {
    let entries = root.get("dice_log")?.as_array()?;
    let fallback_turn = root.get("turn").and_then(Value::as_u64).unwrap_or(0) as u32;
    let fallback_phase = root
        .get("phase")
        .and_then(Value::as_str)
        .unwrap_or("dm_narration");
    let fallback_workspace_id = root
        .get("workspace_id")
        .or_else(|| root.get("id"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();

    let mut output = Vec::new();
    for entry in entries {
        if let Some(row) =
            parse_dice_log_entry(entry, fallback_turn, fallback_phase, &fallback_workspace_id)
        {
            output.push(row);
        }
    }
    Some(output)
}

fn parse_dice_log_entry(
    entry: &Value,
    fallback_turn: u32,
    _fallback_phase: &str,
    fallback_workspace_id: &str,
) -> Option<DiceRollPayload> {
    if !entry.is_object() {
        return None;
    }

    let turn = entry
        .get("turn")
        .and_then(Value::as_u64)
        .and_then(|v| u32::try_from(v).ok())
        .unwrap_or(fallback_turn);
    let character = entry
        .get("character")
        .or_else(|| entry.get("actor_id"))
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_string();
    let action = entry
        .get("action")
        .or_else(|| entry.get("result"))
        .and_then(Value::as_str)
        .unwrap_or("manual_roll")
        .to_string();
    let bonus = entry
        .get("bonus")
        .and_then(Value::as_i64)
        .and_then(|v| i32::try_from(v).ok())
        .unwrap_or(0);
    let raw_d20 = entry
        .get("raw_d20")
        .or_else(|| entry.get("d20"))
        .and_then(Value::as_i64)
        .and_then(|v| i32::try_from(v).ok())
        .unwrap_or(0);
    let dc = entry
        .get("dc")
        .or_else(|| entry.get("difficulty"))
        .and_then(Value::as_i64)
        .and_then(|v| i32::try_from(v).ok())
        .unwrap_or(0);
    let total = entry
        .get("total")
        .and_then(Value::as_i64)
        .and_then(|v| i32::try_from(v).ok())
        .unwrap_or(raw_d20 + bonus);
    let raw_result = entry
        .get("label")
        .or_else(|| entry.get("tier"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let result = map_dice_result_label(raw_result);

    let tier = entry
        .get("tier")
        .and_then(Value::as_str)
        .map(str::to_string);
    let label = entry
        .get("label")
        .and_then(Value::as_str)
        .map(str::to_string);
    let passed = entry.get("passed").and_then(Value::as_bool);
    let stat_value = entry
        .get("stat_value")
        .and_then(Value::as_i64)
        .and_then(|v| i32::try_from(v).ok());

    Some(DiceRollPayload {
        turn,
        workspace_id: entry
            .get("workspace_id")
            .and_then(Value::as_str)
            .unwrap_or(fallback_workspace_id)
            .trim()
            .to_string(),
        character,
        action,
        d20: raw_d20,
        bonus,
        total,
        dc,
        result,
        note: entry
            .get("note")
            .and_then(Value::as_str)
            .map(str::to_string),
        tier,
        label,
        passed,
        stat_value,
    })
}

fn map_dice_result_label(raw: &str) -> String {
    let raw = raw.trim().to_ascii_lowercase();
    match raw.as_str() {
        "critical_fail" | "critical failure" | "fumble" | "대실패" => {
            "critical_fail".to_string()
        }
        "fail" | "failure" | "실패" => "fail".to_string(),
        "partial" | "partial_success" | "부분성공" => "partial_success".to_string(),
        "success" | "성공" => "success".to_string(),
        "great" | "great_success" | "대성공" => "great_success".to_string(),
        "miracle" | "기적" => "miracle".to_string(),
        "대승리" => "miracle".to_string(),
        "pass" | "passed" | "true" | "1" | "success!" => "success".to_string(),
        "false" | "0" => "fail".to_string(),
        _ => {
            let passed = entry_passed_marker(&raw);
            if passed { "success" } else { "fail" }.to_string()
        }
    }
}

fn entry_passed_marker(raw: &str) -> bool {
    let compact = raw.replace(['\n', '\r', '\t'], " ");
    compact
        .split_whitespace()
        .find(|token| !token.is_empty())
        .is_some_and(|token| matches!(token, "pass" | "passed" | "success" | "성공" | "true" | "1"))
}

fn parse_party_characters(
    state: &Value,
    actor_control: &HashMap<String, String>,
) -> Vec<CharacterData> {
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
            let archetype = info
                .get("archetype")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let persona = info
                .get("persona")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let traits = info
                .get("traits")
                .and_then(Value::as_array)
                .map(|rows| {
                    rows.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_string)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
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
            let mp = info
                .get("mp")
                .and_then(Value::as_i64)
                .and_then(|x| i32::try_from(x).ok())
                .unwrap_or_default();
            let max_mp = info
                .get("max_mp")
                .and_then(Value::as_i64)
                .and_then(|x| i32::try_from(x).ok())
                .unwrap_or(mp);
            let skills = info
                .get("skills")
                .and_then(Value::as_array)
                .map(|rows| {
                    rows.iter()
                        .filter_map(|skill| {
                            if let Ok(parsed) = serde_json::from_value::<SkillData>(skill.clone()) {
                                Some(parsed)
                            } else {
                                skill.as_str().map(|name| SkillData {
                                    name: name.to_string(),
                                    level: 10,
                                    description: String::new(),
                                    usage_hint: String::new(),
                                })
                            }
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let conditions = info
                .get("conditions")
                .and_then(Value::as_array)
                .map(|rows| {
                    rows.iter()
                        .filter_map(|cond| {
                            if let Ok(parsed) =
                                serde_json::from_value::<ConditionData>(cond.clone())
                            {
                                Some(parsed)
                            } else {
                                cond.as_str().map(|name| ConditionData {
                                    name: name.to_string(),
                                    remaining_turns: None,
                                })
                            }
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let equipment = info
                .get("equipment")
                .and_then(Value::as_array)
                .map(|rows| {
                    rows.iter()
                        .filter_map(|slot| {
                            if let Ok(parsed) =
                                serde_json::from_value::<EquipmentData>(slot.clone())
                            {
                                Some(parsed)
                            } else {
                                slot.as_str().map(|name| EquipmentData {
                                    slot: "item".to_string(),
                                    name: name.to_string(),
                                })
                            }
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let keeper = actor_control.get(actor_id).cloned().unwrap_or_default();

            CharacterData {
                id: actor_id.to_string(),
                name,
                class,
                archetype,
                persona,
                traits,
                hp,
                max_hp,
                mp,
                max_mp,
                stats,
                area,
                is_dead,
                inventory,
                buffs,
                debuffs,
                skills,
                conditions,
                equipment,
                keeper,
            }
        })
        .collect()
}

/// When the fetched workspace is not resumable, surface guidance for starting a new
/// session. The new-game panel itself should remain user-triggered.
fn prompt_new_game_for_inactive_workspace(workspace_status: &str) {
    #[cfg(not(target_arch = "wasm32"))]
    let _ = workspace_status;

    #[cfg(target_arch = "wasm32")]
    {
        let Some(document) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        let mut should_bootstrap = false;
        // Show the new-game panel
        if let Some(panel) = document.get_element_by_id("new-game-panel") {
            let was_visible = panel
                .dyn_ref::<web_sys::HtmlElement>()
                .and_then(|html_el| html_el.style().get_property_value("display").ok())
                .map(|display| {
                    matches!(
                        display.trim().to_ascii_lowercase().as_str(),
                        "flex" | "block" | "grid" | "inline-flex"
                    )
                })
                .unwrap_or(false);
            if let Some(html_el) = panel.dyn_ref::<web_sys::HtmlElement>() {
                let _ = html_el.style().set_property("display", "flex");
            }
            if !was_visible {
                should_bootstrap = true;
            }
        }

        // Pre-populate workspace ID input with a fresh generated ID
        if let Some(input) = document
            .get_element_by_id("new-game-workspace-id")
            .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
        {
            if input.value().trim().is_empty() {
                let ts = js_sys::Date::now() as i64;
                let rand = (js_sys::Math::random() * 1000.0).floor() as i64;
                input.set_value(&format!("adventure-{}-{:03}", ts, rand));
            }
        }

        // Set a status message appropriate to the workspace state
        if let Some(el) = document.get_element_by_id("new-game-status") {
            let msg = match normalize_workspace_status(workspace_status).as_str() {
                "ended" => "이 게임은 종료되었습니다. 새 게임을 시작하세요.",
                "unavailable" => {
                    "엔진에 연결할 수 없습니다. 새 게임을 시작하면 재연결을 시도합니다."
                }
                _ => "진행 중인 게임이 없습니다. 새 게임을 시작하세요.",
            };
            el.set_inner_html(msg);
        }

        // Trigger bootstrap once when auto-opening the panel for an inactive workspace.
        if should_bootstrap {
            if let Some(btn) = document.get_element_by_id("new-game-toggle") {
                if let Some(html_btn) = btn.dyn_ref::<web_sys::HtmlElement>() {
                    html_btn.click();
                }
            }
        }
    }
}

fn unavailable_game_state(workspace_id: &str) -> GameStateResponse {
    GameStateResponse {
        workspace: Some(WorkspaceResponse {
            id: workspace_id.to_string(),
            status: "unavailable".to_string(),
            turn: 0,
            phase: "dm_narration".to_string(),
            current_scenario: "".to_string(),
            current_node: "".to_string(),
        }),
        characters: Vec::new(),
        dm_keeper: String::new(),
        current_area: "".to_string(),
        area_label: "".to_string(),
        dice_log: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn normalize_legacy_shape() {
        let root = json!({
            "workspace": {
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
        assert_eq!(parsed.workspace.as_ref().map(|r| r.turn), Some(2));
        assert_eq!(parsed.current_area, "A");
    }

    #[test]
    fn normalize_hybrid_shape_backfills_workspace_from_state() {
        let root = json!({
            "workspace": {
                "id": "default"
            },
            "state": {
                "workspace_id": "default",
                "status": "active",
                "turn": 40,
                "phase": "round",
                "current_area": "A",
                "area_label": "Forest Entrance",
                "party": {
                    "hero-1": {
                        "name": "Hero",
                        "role": "fighter",
                        "hp": 10,
                        "max_hp": 10,
                        "position": "A",
                        "alive": true
                    }
                }
            }
        });

        let parsed = normalize_state_response(root).expect("hybrid parse should succeed");
        let workspace = parsed.workspace.as_ref().expect("workspace should exist");
        assert_eq!(workspace.status, "active");
        assert_eq!(workspace.turn, 40);
        assert_eq!(workspace.phase, "round");
        assert_eq!(parsed.current_area, "A");
        assert_eq!(parsed.area_label, "Forest Entrance");
        assert_eq!(parsed.characters.len(), 1);
    }

    #[test]
    fn normalize_masc_shape_uses_defaults_without_fallback_party() {
        let root = json!({
            "ok": true,
            "workspace_id": "default",
            "state": {
                "turn": 5,
                "phase": "dm_narration",
                "current_area": "C"
            }
        });

        let parsed = normalize_state_response(root).expect("masc parse should succeed");
        assert_eq!(parsed.workspace.as_ref().map(|r| r.turn), Some(5));
        assert_eq!(parsed.current_area, "C");
        assert!(
            parsed.characters.is_empty(),
            "no fallback party should be injected"
        );
    }

    #[test]
    fn normalize_masc_shape_reads_party_as_characters() {
        let root = json!({
            "ok": true,
            "workspace_id": "default",
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
    fn normalize_masc_shape_maps_actor_control_and_dm_keeper() {
        let root = json!({
            "ok": true,
            "workspace_id": "default",
            "state": {
                "turn": 4,
                "phase": "round",
                "dm": { "keeper_name": "trpg-dm" },
                "actor_control": {
                    "grimja": "trpg-grimja",
                    "luna": "trpg-luna"
                },
                "party": {
                    "grimja": {
                        "name": "그림자",
                        "role": "fighter",
                        "hp": 28,
                        "max_hp": 30,
                        "position": "C",
                        "alive": true
                    },
                    "luna": {
                        "name": "루나",
                        "role": "mage",
                        "hp": 13,
                        "max_hp": 15,
                        "position": "F",
                        "alive": true
                    }
                }
            }
        });

        let parsed = normalize_state_response(root).expect("masc parse should succeed");
        assert_eq!(parsed.dm_keeper, "trpg-dm");
        assert_eq!(parsed.characters.len(), 2);
        let grimja = parsed
            .characters
            .iter()
            .find(|row| row.id == "grimja")
            .expect("grimja row");
        assert_eq!(grimja.keeper, "trpg-grimja");
        let luna = parsed
            .characters
            .iter()
            .find(|row| row.id == "luna")
            .expect("luna row");
        assert_eq!(luna.keeper, "trpg-luna");
    }

    #[test]
    fn normalize_masc_shape_infers_dm_keeper_from_narration_log() {
        let root = json!({
            "ok": true,
            "workspace_id": "default",
            "state": {
                "turn": 2,
                "phase": "dm_narration",
                "actor_control": {
                    "grimja": "trpg-grimja"
                },
                "narration_log": [
                    {
                        "turn": 1,
                        "role": "player",
                        "actor_id": "grimja",
                        "keeper": "trpg-grimja"
                    },
                    {
                        "turn": 2,
                        "role": "dm",
                        "actor_id": "dm",
                        "keeper": "  trpg-dm  "
                    }
                ]
            }
        });

        let parsed = normalize_state_response(root).expect("masc parse should succeed");
        assert_eq!(parsed.dm_keeper, "trpg-dm");
    }

    #[test]
    fn normalize_masc_shape_ignores_stale_narration_keeper_mapping() {
        let root = json!({
            "ok": true,
            "workspace_id": "default",
            "state": {
                "turn": 2,
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
                },
                "narration_log": [
                    {
                        "turn": 1,
                        "role": "player",
                        "actor_id": "grimja",
                        "keeper": "old-keeper"
                    }
                ]
            }
        });

        let parsed = normalize_state_response(root).expect("masc parse should succeed");
        assert_eq!(parsed.characters.len(), 1);
        assert_eq!(parsed.characters[0].keeper, "");
    }

    #[test]
    fn ended_workspace_is_not_active() {
        let root = json!({
            "workspace": {
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

        let parsed = normalize_state_response(root).expect("ended workspace parse should succeed");
        let status = parsed
            .workspace
            .as_ref()
            .map(|r| r.status.as_str())
            .unwrap_or("");
        assert_ne!(
            status, "active",
            "ended workspace should not be treated as active"
        );
        assert_eq!(status, "ended");
        assert_eq!(
            parsed.characters.len(),
            1,
            "characters still parsed even for ended workspaces"
        );
    }

    #[test]
    fn idle_workspace_is_not_active() {
        let root = json!({
            "workspace": {
                "id": "default",
                "status": "idle",
                "turn": 0,
                "phase": "dm_narration"
            },
            "characters": [],
            "current_area": "",
            "area_label": ""
        });

        let parsed = normalize_state_response(root).expect("idle workspace parse should succeed");
        let status = parsed
            .workspace
            .as_ref()
            .map(|r| r.status.as_str())
            .unwrap_or("");
        assert_ne!(status, "active");
        assert!(parsed.characters.is_empty());
    }

    #[test]
    fn unavailable_game_state_has_correct_shape() {
        let state = unavailable_game_state("test-workspace");
        let workspace = state
            .workspace
            .as_ref()
            .expect("workspace should be present");
        assert_eq!(workspace.id, "test-workspace");
        assert_eq!(workspace.status, "unavailable");
        assert!(state.characters.is_empty());
    }

    #[test]
    fn paused_workspace_is_resumable() {
        assert!(!workspace_requires_new_game("paused"));
    }

    #[test]
    fn ended_workspace_requires_new_game() {
        assert!(workspace_requires_new_game("ended"));
        assert!(workspace_requires_new_game("completed"));
        assert!(workspace_requires_new_game("done"));
        assert!(workspace_requires_new_game("closed"));
    }

    #[test]
    fn initial_progress_event_is_hidden_for_idle() {
        assert_eq!(initial_progress_event_type("idle", false), None);
    }

    #[test]
    fn initial_progress_event_marks_ended_workspace_as_ended_event() {
        assert_eq!(
            initial_progress_event_type("ended", false),
            Some("workspace.ended")
        );
    }

    #[test]
    fn initial_progress_event_marks_completed_workspace_as_ended_event() {
        assert_eq!(
            initial_progress_event_type("completed", false),
            Some("workspace.ended")
        );
    }

    #[test]
    fn initial_progress_event_is_suppressed_when_workspace_state_unavailable() {
        assert_eq!(initial_progress_event_type("running", true), None);
    }

    #[test]
    fn initial_turn_advanced_requires_turn_and_resumable_status() {
        assert!(should_emit_initial_turn_advanced(3, "running", false));
        assert!(!should_emit_initial_turn_advanced(0, "running", false));
        assert!(!should_emit_initial_turn_advanced(3, "ended", false));
        assert!(!should_emit_initial_turn_advanced(3, "running", true));
    }

    #[test]
    fn normalize_workspace_status_is_case_insensitive() {
        assert_eq!(normalize_workspace_status("  AcTiVe "), "active");
    }
}
