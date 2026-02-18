//! TRPG controls — actor admin CRUD, new game flow, preset system, UI event binding.
//!
//! Extracted from `mod.rs` to reduce file size.
//! All items are `#[cfg(target_arch = "wasm32")]` gated at the module level
//! (the parent `mod trpg_controls` declaration carries the gate).

use serde_json::{json, Value};
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use wasm_bindgen_futures::JsFuture;

use crate::dom::escape::html_escape;

use super::{
    assign_keepers_to_actor_ids, clear_trpg_dom, generate_room_id, mcp_tool_call,
    parse_embedded_tool_payload, render_dedup_popover, set_current_room_id, set_element_display,
    set_new_game_preflight_rows, set_new_game_preflight_status, set_new_game_status,
    set_round_run_fields, unique_non_empty,
};

// ─── Structs ─────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
struct PresetOption {
    id: String,
    title: String,
}

#[derive(Debug, Clone)]
struct NewGameBootstrap {
    keepers: Vec<String>,
    world_presets: Vec<PresetOption>,
    dm_presets: Vec<PresetOption>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ActorAdminRow {
    actor_id: String,
    name: String,
    role: String,
    hp: i32,
    max_hp: i32,
    keeper: String,
}

// ─── Helpers (moved from mod.rs, only used here) ────────────────

fn parse_keeper_models(raw: &str) -> Vec<String> {
    unique_non_empty(
        raw.split(',')
            .map(|part| part.trim().to_string())
            .collect::<Vec<_>>(),
    )
}

fn selected_player_keepers(doc: &web_sys::Document) -> Vec<String> {
    let Ok(nodes) = doc.query_selector_all("#new-game-player-select option:checked") else {
        return Vec::new();
    };
    let mut keepers = Vec::new();
    for i in 0..nodes.length() {
        let Some(node) = nodes.item(i) else { continue };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };
        let Some(value) = el.get_attribute("value") else {
            continue;
        };
        let value = value.trim();
        if value.is_empty() {
            continue;
        }
        keepers.push(value.to_string());
    }
    unique_non_empty(keepers)
}

fn available_player_keepers(doc: &web_sys::Document) -> Vec<String> {
    let Ok(nodes) = doc.query_selector_all("#new-game-player-select option") else {
        return Vec::new();
    };
    let mut keepers = Vec::new();
    for i in 0..nodes.length() {
        let Some(node) = nodes.item(i) else { continue };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };
        let Some(value) = el.get_attribute("value") else {
            continue;
        };
        let value = value.trim();
        if value.is_empty() {
            continue;
        }
        keepers.push(value.to_string());
    }
    unique_non_empty(keepers)
}

fn apply_player_keeper_selection(doc: &web_sys::Document, selected: &[String]) {
    let selected = unique_non_empty(selected.to_vec());
    if let Ok(nodes) = doc.query_selector_all("#new-game-player-select option") {
        for i in 0..nodes.length() {
            let Some(node) = nodes.item(i) else { continue };
            let Some(el) = node.dyn_ref::<web_sys::Element>() else {
                continue;
            };
            let value = el
                .get_attribute("value")
                .unwrap_or_default()
                .trim()
                .to_string();
            let on = !value.is_empty() && selected.iter().any(|picked| picked == &value);
            if on {
                let _ = el.set_attribute("selected", "selected");
            } else {
                let _ = el.remove_attribute("selected");
            }
        }
    }
}

fn extract_keeper_name_from_value(row: &Value) -> Option<String> {
    row.as_str()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_string)
        .or_else(|| {
            row.get("name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(str::to_string)
        })
        .or_else(|| {
            row.get("keeper")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(str::to_string)
        })
}

// ─── Keeper Selectors ───────────────────────────────────────────

async fn refresh_keeper_selectors(doc: &web_sys::Document) -> Result<Vec<String>, String> {
    let payload = mcp_tool_call("masc_keeper_list", json!({ "limit": 200 })).await?;
    web_sys::console::log_1(&format!("[refresh_keeper_selectors] payload keys={:?}", payload.as_object().map(|m| m.keys().collect::<Vec<_>>())).into());
    let mut keepers = payload
        .get("keepers")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(extract_keeper_name_from_value)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    keepers = unique_non_empty(keepers);
    if keepers.is_empty() {
        let mut fallback = Vec::new();
        let dm_from_ui = doc
            .get_element_by_id("new-game-dm-select")
            .and_then(|el| {
                el.dyn_ref::<web_sys::HtmlSelectElement>()
                    .map(|s| s.value())
            })
            .unwrap_or_default()
            .trim()
            .to_string();
        if !dm_from_ui.is_empty() {
            fallback.push(dm_from_ui);
        }
        if let Some(claimed) = doc.get_element_by_id("claimed-keeper") {
            if let Some(input) = claimed.dyn_ref::<web_sys::HtmlInputElement>() {
                let value = input.value().trim().to_string();
                if !value.is_empty() {
                    fallback.push(value);
                }
            }
            let text = claimed.text_content().unwrap_or_default().trim().to_string();
            if !text.is_empty() {
                fallback.push(text);
            }
        }
        keepers = unique_non_empty(fallback);
    }
    if keepers.is_empty() {
        return Err("keeper 목록이 비어 있습니다. masc_keeper_list 결과를 확인하세요.".to_string());
    }

    let previous_dm = doc
        .get_element_by_id("new-game-dm-select")
        .and_then(|el| {
            el.dyn_ref::<web_sys::HtmlSelectElement>()
                .map(|s| s.value())
        })
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty());
    let previous_players = selected_player_keepers(doc);
    let dm_default = previous_dm
        .filter(|prev| keepers.iter().any(|name| name == prev))
        .or_else(|| keepers.iter().find(|name| name.starts_with("dm")).cloned())
        .unwrap_or_else(|| keepers[0].clone());

    if let Some(dm_select) = doc.get_element_by_id("new-game-dm-select") {
        let html = keepers
            .iter()
            .map(|name| {
                let safe = html_escape(name);
                format!(r#"<option value="{}">{}</option>"#, safe, safe)
            })
            .collect::<Vec<_>>()
            .join("");
        dm_select.set_inner_html(&html);
        if let Some(select) = dm_select.dyn_ref::<web_sys::HtmlSelectElement>() {
            select.set_value(&dm_default);
        }
    }

    if let Some(player_select) = doc.get_element_by_id("new-game-player-select") {
        let preserve_existing_selection = !previous_players.is_empty();
        let mut default_selected = 0_usize;
        let mut html = String::new();
        for name in keepers.iter().filter(|name| **name != dm_default) {
            let safe = html_escape(name);
            let selected_attr = if preserve_existing_selection
                && previous_players.iter().any(|picked| picked == name)
            {
                " selected"
            } else if !preserve_existing_selection && default_selected < 4 {
                default_selected += 1;
                " selected"
            } else {
                ""
            };
            html.push_str(&format!(
                r#"<option value="{value}"{selected}>{value}</option>"#,
                value = safe,
                selected = selected_attr
            ));
        }
        player_select.set_inner_html(&html);
    }

    Ok(keepers)
}

// ─── Actor Admin CRUD ───────────────────────────────────────────

fn actor_admin_room_id() -> String {
    crate::config::current_room_id()
}

fn actor_admin_set_status(doc: &web_sys::Document, message: &str, css_class: &str) {
    if let Some(el) = doc.get_element_by_id("actor-admin-status") {
        el.set_inner_html(&html_escape(message));
        let class_name = if css_class.trim().is_empty() {
            "new-game-status".to_string()
        } else {
            format!("new-game-status {}", css_class)
        };
        let _ = el.set_attribute("class", &class_name);
    }
}

fn actor_admin_set_busy(doc: &web_sys::Document, busy: bool) {
    for id in [
        "actor-admin-refresh",
        "actor-admin-spawn",
        "actor-admin-update",
        "actor-admin-delete",
    ] {
        if let Some(btn) = doc
            .get_element_by_id(id)
            .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
        {
            btn.set_disabled(busy);
        }
    }
}

fn actor_admin_input_value(doc: &web_sys::Document, id: &str) -> String {
    doc.get_element_by_id(id)
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
        .map(|input| input.value().trim().to_string())
        .unwrap_or_default()
}

fn actor_admin_select_value(doc: &web_sys::Document, id: &str) -> String {
    doc.get_element_by_id(id)
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
        .map(|select| select.value().trim().to_string())
        .unwrap_or_default()
}

fn actor_admin_input_i64(doc: &web_sys::Document, id: &str) -> Option<i64> {
    let raw = actor_admin_input_value(doc, id);
    if raw.is_empty() {
        None
    } else {
        raw.parse::<i64>().ok()
    }
}

async fn fetch_room_state_payload(room_id: &str) -> Result<Value, String> {
    let url = format!(
        "{}/api/v1/trpg/state?room_id={}",
        crate::config::MASC_MCP_URL,
        room_id
    );
    let opts = web_sys::RequestInit::new();
    opts.set_method("GET");
    opts.set_mode(web_sys::RequestMode::Cors);

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)
        .map_err(|e| format!("request 생성 실패: {:?}", e))?;
    request
        .headers()
        .set("Accept", "application/json")
        .map_err(|e| format!("헤더 설정 실패: {:?}", e))?;

    let window = web_sys::window().ok_or_else(|| "window unavailable".to_string())?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request))
        .await
        .map_err(|e| format!("fetch 실패: {:?}", e))?;
    let resp: web_sys::Response = resp_value
        .dyn_into()
        .map_err(|_| "response 변환 실패".to_string())?;
    if !resp.ok() {
        return Err(format!("HTTP {}", resp.status()));
    }

    let body_js = JsFuture::from(
        resp.text()
            .map_err(|e| format!("response.text() 실패: {:?}", e))?,
    )
    .await
    .map_err(|e| format!("본문 읽기 실패: {:?}", e))?;
    let body = body_js.as_string().unwrap_or_default();
    if body.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str::<Value>(&body).map_err(|e| format!("state JSON 파싱 실패: {}", e))
}

fn parse_actor_admin_rows(state_root: &Value) -> Vec<ActorAdminRow> {
    let state = state_root.get("state").unwrap_or(state_root);
    let actor_control = state
        .get("actor_control")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let control_keeper = |actor_id: &str| -> String {
        actor_control
            .get(actor_id)
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string()
    };

    let mut rows = Vec::new();
    if let Some(characters) = state.get("characters").and_then(Value::as_array) {
        for ch in characters {
            let actor_id = ch
                .get("id")
                .or_else(|| ch.get("actor_id"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_string();
            if actor_id.is_empty() {
                continue;
            }
            let name = ch
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or(&actor_id)
                .trim()
                .to_string();
            let role = ch
                .get("role")
                .or_else(|| ch.get("class"))
                .or_else(|| ch.get("archetype"))
                .and_then(Value::as_str)
                .unwrap_or("player")
                .trim()
                .to_string();
            let hp = ch.get("hp").and_then(Value::as_i64).unwrap_or(0) as i32;
            let max_hp = ch.get("max_hp").and_then(Value::as_i64).unwrap_or(0) as i32;
            let keeper = ch
                .get("keeper")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_string();
            rows.push(ActorAdminRow {
                actor_id: actor_id.clone(),
                name,
                role,
                hp,
                max_hp,
                keeper: if keeper.is_empty() {
                    control_keeper(&actor_id)
                } else {
                    keeper
                },
            });
        }
    } else if let Some(party) = state.get("party").and_then(Value::as_object) {
        for (actor_id, row) in party {
            let actor_id = actor_id.trim();
            if actor_id.is_empty() {
                continue;
            }
            let name = row
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or(actor_id)
                .trim()
                .to_string();
            let role = row
                .get("role")
                .or_else(|| row.get("class"))
                .or_else(|| row.get("archetype"))
                .and_then(Value::as_str)
                .unwrap_or("player")
                .trim()
                .to_string();
            let hp = row.get("hp").and_then(Value::as_i64).unwrap_or(0) as i32;
            let max_hp = row.get("max_hp").and_then(Value::as_i64).unwrap_or(0) as i32;
            rows.push(ActorAdminRow {
                actor_id: actor_id.to_string(),
                name,
                role,
                hp,
                max_hp,
                keeper: control_keeper(actor_id),
            });
        }
    }
    rows.sort_by(|a, b| a.actor_id.cmp(&b.actor_id));
    rows
}

fn render_actor_admin_rows(doc: &web_sys::Document, rows: &[ActorAdminRow]) {
    let Some(list) = doc.get_element_by_id("actor-admin-list") else {
        return;
    };
    if rows.is_empty() {
        list.set_inner_html("<div class=\"room-chip-empty\">액터가 없습니다.</div>");
        return;
    }
    let html = rows
        .iter()
        .map(|row| {
            format!(
                concat!(
                    "<button class=\"actor-admin-row\" ",
                    "data-actor-id=\"{id}\" data-name=\"{name}\" data-role=\"{role}\" ",
                    "data-keeper=\"{keeper}\" data-hp=\"{hp}\" data-max-hp=\"{max_hp}\">",
                    "{id} · {role} · HP {hp}/{max_hp}{keeper_text}",
                    "</button>"
                ),
                id = html_escape(&row.actor_id),
                name = html_escape(&row.name),
                role = html_escape(&row.role),
                keeper = html_escape(&row.keeper),
                hp = row.hp,
                max_hp = row.max_hp,
                keeper_text = if row.keeper.is_empty() {
                    "".to_string()
                } else {
                    format!(" · keeper {}", html_escape(&row.keeper))
                },
            )
        })
        .collect::<Vec<_>>()
        .join("");
    list.set_inner_html(&html);
}

fn bind_actor_admin_row_clicks(doc: &web_sys::Document) {
    let Ok(nodes) = doc.query_selector_all("#actor-admin-list .actor-admin-row") else {
        return;
    };
    for i in 0..nodes.length() {
        let Some(node) = nodes.item(i) else { continue };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };
        if el.get_attribute("data-bound").as_deref() == Some("1") {
            continue;
        }
        let _ = el.set_attribute("data-bound", "1");
        let id = el.get_attribute("data-actor-id").unwrap_or_default();
        let name = el.get_attribute("data-name").unwrap_or_default();
        let role = el.get_attribute("data-role").unwrap_or_default();
        let keeper = el.get_attribute("data-keeper").unwrap_or_default();
        let hp = el.get_attribute("data-hp").unwrap_or_default();
        let max_hp = el.get_attribute("data-max-hp").unwrap_or_default();
        let cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };

            if let Some(input) = doc
                .get_element_by_id("actor-admin-id")
                .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
            {
                input.set_value(&id);
            }
            if let Some(input) = doc
                .get_element_by_id("actor-admin-name")
                .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
            {
                input.set_value(&name);
            }
            if let Some(select) = doc
                .get_element_by_id("actor-admin-role")
                .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
            {
                if !role.trim().is_empty() {
                    select.set_value(&role);
                }
            }
            if let Some(input) = doc
                .get_element_by_id("actor-admin-keeper")
                .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
            {
                input.set_value(&keeper);
            }
            if let Some(input) = doc
                .get_element_by_id("actor-admin-hp")
                .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
            {
                input.set_value(&hp);
            }
            if let Some(input) = doc
                .get_element_by_id("actor-admin-max-hp")
                .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
            {
                input.set_value(&max_hp);
            }
        }) as Box<dyn FnMut()>);
        let _ = el.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
        });
        cb.forget();
    }
}

async fn refresh_actor_admin_list(doc: &web_sys::Document) -> Result<Vec<ActorAdminRow>, String> {
    let room_id = actor_admin_room_id();
    let payload = fetch_room_state_payload(&room_id).await?;
    let rows = parse_actor_admin_rows(&payload);
    render_actor_admin_rows(doc, &rows);
    bind_actor_admin_row_clicks(doc);
    Ok(rows)
}

async fn refresh_new_game_bootstrap(doc: &web_sys::Document) -> Result<NewGameBootstrap, String> {
    let keepers = refresh_keeper_selectors(doc).await?;
    let (world_presets, dm_presets) = refresh_preset_selectors(doc).await?;
    if let Err(err) = refresh_actor_admin_list(doc).await {
        actor_admin_set_status(doc, &format!("액터 목록 로드 실패: {}", err), "status-warn");
    }
    Ok(NewGameBootstrap {
        keepers,
        world_presets,
        dm_presets,
    })
}

async fn run_new_game_preflight(doc: &web_sys::Document) -> Result<(), String> {
    let mut rows: Vec<(bool, String, String)> = Vec::new();

    let preset_row = match mcp_tool_call(
        "trpg.preset.list",
        json!({
            "include_characters": false,
            "include_skills": false
        }),
    )
    .await
    {
        Ok(raw_catalog) => {
            let catalog = normalize_preset_catalog(&raw_catalog);
            let world = collect_preset_options_from_catalog(
                &catalog,
                &["world_presets", "world", "world_preset", "worlds"],
            );
            let dm =
                collect_preset_options_from_catalog(&catalog, &["dm_presets", "dm", "dm_preset", "dms"]);
            let ok = !world.is_empty() && !dm.is_empty();
            let detail = if ok {
                format!("월드 {}개 · DM {}개", world.len(), dm.len())
            } else {
                format!("프리셋 부족 (월드 {} / DM {})", world.len(), dm.len())
            };
            (ok, "프리셋".to_string(), detail)
        }
        Err(e) => (
            false,
            "프리셋".to_string(),
            format!("조회 실패: {}", e),
        ),
    };
    rows.push(preset_row);

    let keeper_row = match mcp_tool_call("masc_keeper_list", json!({ "limit": 200 })).await {
        Ok(payload) => {
            let count = payload
                .get("keepers")
                .and_then(Value::as_array)
                .map(|rows| rows.len())
                .unwrap_or(0);
            if count > 0 {
                (
                    true,
                    "키퍼 풀".to_string(),
                    format!("{}명 사용 가능", count),
                )
            } else {
                (
                    false,
                    "키퍼 풀".to_string(),
                    "사용 가능한 keeper가 없습니다".to_string(),
                )
            }
        }
        Err(e) => (
            false,
            "키퍼 풀".to_string(),
            format!("조회 실패: {}", e),
        ),
    };
    rows.push(keeper_row);

    let room_id = actor_admin_room_id();
    let room_row = match fetch_room_state_payload(&room_id).await {
        Ok(payload) => {
            let root = payload.get("state").unwrap_or(&payload);
            let status = root
                .get("status")
                .and_then(Value::as_str)
                .or_else(|| payload.get("status").and_then(Value::as_str))
                .unwrap_or("unknown")
                .trim()
                .to_string();
            (
                true,
                "룸 상태".to_string(),
                format!("room {} · {}", room_id, status),
            )
        }
        Err(e) => (
            false,
            "룸 상태".to_string(),
            format!("room {} 조회 실패: {}", room_id, e),
        ),
    };
    rows.push(room_row);

    set_new_game_preflight_rows(doc, &rows);
    if rows.iter().all(|(ok, _, _)| *ok) {
        Ok(())
    } else {
        Err("사전 점검 실패 항목이 있습니다.".to_string())
    }
}

async fn actor_admin_spawn(doc: &web_sys::Document) -> Result<String, String> {
    let room_id = actor_admin_room_id();
    let actor_id = actor_admin_input_value(doc, "actor-admin-id");
    if actor_id.is_empty() {
        return Err("Actor ID를 입력하세요.".to_string());
    }
    let role = {
        let role_raw = actor_admin_select_value(doc, "actor-admin-role");
        if role_raw.is_empty() {
            "player".to_string()
        } else {
            role_raw
        }
    };
    let name = actor_admin_input_value(doc, "actor-admin-name");
    let keeper = actor_admin_input_value(doc, "actor-admin-keeper");
    let max_hp = actor_admin_input_i64(doc, "actor-admin-max-hp").unwrap_or(20);
    let hp = actor_admin_input_i64(doc, "actor-admin-hp").unwrap_or(max_hp);

    let mut args = json!({
        "room_id": room_id,
        "actor_id": actor_id,
        "role": role,
        "hp": hp.max(0),
        "max_hp": max_hp.max(1),
        "alive": hp > 0
    });
    if !name.is_empty() {
        args["name"] = Value::String(name);
    }
    mcp_tool_call("trpg.actor.spawn", args).await?;
    if !keeper.is_empty() {
        mcp_tool_call(
            "trpg.actor.claim",
            json!({
                "room_id": actor_admin_room_id(),
                "actor_id": actor_id,
                "keeper_name": keeper
            }),
        )
        .await?;
    }
    let rows = refresh_actor_admin_list(doc).await?;
    Ok(format!("액터 생성 완료 ({}명): {}", rows.len(), actor_id))
}

async fn actor_admin_update(doc: &web_sys::Document) -> Result<String, String> {
    let room_id = actor_admin_room_id();
    let actor_id = actor_admin_input_value(doc, "actor-admin-id");
    if actor_id.is_empty() {
        return Err("수정할 Actor ID를 입력하세요.".to_string());
    }
    let name = actor_admin_input_value(doc, "actor-admin-name");
    let role = actor_admin_select_value(doc, "actor-admin-role");
    let keeper = actor_admin_input_value(doc, "actor-admin-keeper");
    let hp = actor_admin_input_i64(doc, "actor-admin-hp");
    let max_hp = actor_admin_input_i64(doc, "actor-admin-max-hp");

    let mut args = json!({
        "room_id": room_id,
        "actor_id": actor_id
    });
    let mut has_patch = false;
    if !name.is_empty() {
        args["name"] = Value::String(name);
        has_patch = true;
    }
    if !role.is_empty() {
        args["role"] = Value::String(role);
        has_patch = true;
    }
    if let Some(hp) = hp {
        args["hp"] = Value::Number(hp.max(0).into());
        args["alive"] = Value::Bool(hp > 0);
        has_patch = true;
    }
    if let Some(max_hp) = max_hp {
        args["max_hp"] = Value::Number(max_hp.max(1).into());
        has_patch = true;
    }
    if !has_patch && keeper.is_empty() {
        return Err("수정할 필드 또는 keeper를 입력하세요.".to_string());
    }

    if has_patch {
        mcp_tool_call("trpg.actor.update", args).await?;
    }
    if !keeper.is_empty() {
        mcp_tool_call(
            "trpg.actor.claim",
            json!({
                "room_id": actor_admin_room_id(),
                "actor_id": actor_id,
                "keeper_name": keeper
            }),
        )
        .await?;
    }
    let rows = refresh_actor_admin_list(doc).await?;
    Ok(format!("액터 수정 완료 ({}명): {}", rows.len(), actor_id))
}

async fn actor_admin_delete(doc: &web_sys::Document) -> Result<String, String> {
    let room_id = actor_admin_room_id();
    let actor_id = actor_admin_input_value(doc, "actor-admin-id");
    if actor_id.is_empty() {
        return Err("삭제할 Actor ID를 입력하세요.".to_string());
    }
    let reason = actor_admin_input_value(doc, "actor-admin-delete-reason");
    let mut args = json!({
        "room_id": room_id,
        "actor_id": actor_id
    });
    if !reason.is_empty() {
        args["reason"] = Value::String(reason);
    }
    mcp_tool_call("trpg.actor.delete", args).await?;
    let rows = refresh_actor_admin_list(doc).await?;
    Ok(format!("액터 삭제 완료 ({}명): {}", rows.len(), actor_id))
}

// ─── New Game Flow ──────────────────────────────────────────────

async fn start_new_game_flow(doc: &web_sys::Document) -> Result<String, String> {
    let room_input = doc
        .get_element_by_id("new-game-room-id")
        .and_then(|el| el.dyn_ref::<web_sys::HtmlInputElement>().map(|i| i.value()))
        .unwrap_or_default();
    let room_id = if room_input.trim().is_empty() {
        generate_room_id()
    } else {
        room_input.trim().to_string()
    };
    if let Some(input) = doc
        .get_element_by_id("new-game-room-id")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_value(&room_id);
    }

    let mut dm_keeper = doc
        .get_element_by_id("new-game-dm-select")
        .and_then(|el| {
            el.dyn_ref::<web_sys::HtmlSelectElement>()
                .map(|s| s.value())
        })
        .unwrap_or_default()
        .trim()
        .to_string();
    if dm_keeper.is_empty() {
        return Err("DM keeper를 선택하세요.".to_string());
    }

    let mut auto_selected_players = false;
    let mut players = selected_player_keepers(doc);
    if players.is_empty() {
        players = available_player_keepers(doc)
            .into_iter()
            .filter(|keeper| keeper != &dm_keeper)
            .collect();
        if players.len() > 4 {
            players.truncate(4);
        }
        players = unique_non_empty(players);
        if !players.is_empty() {
            apply_player_keeper_selection(doc, &players);
            auto_selected_players = true;
        }
    }
    if players.is_empty() {
        if refresh_keeper_selectors(doc).await.is_ok() {
            let refreshed_dm = doc
                .get_element_by_id("new-game-dm-select")
                .and_then(|el| {
                    el.dyn_ref::<web_sys::HtmlSelectElement>()
                        .map(|s| s.value())
                })
                .unwrap_or_default()
                .trim()
                .to_string();
            if !refreshed_dm.is_empty() {
                dm_keeper = refreshed_dm;
            }

            players = selected_player_keepers(doc);
            if players.is_empty() {
                players = available_player_keepers(doc)
                    .into_iter()
                    .filter(|keeper| keeper != &dm_keeper)
                    .collect();
            }
            if players.len() > 4 {
                players.truncate(4);
            }
            players = unique_non_empty(players);
            if !players.is_empty() {
                apply_player_keeper_selection(doc, &players);
                auto_selected_players = true;
            }
        }
    }
    players.retain(|keeper| keeper != &dm_keeper);
    players = unique_non_empty(players);
    if players.len() > 8 {
        players.truncate(8);
        apply_player_keeper_selection(doc, &players);
    }
    if players.is_empty() {
        return Err("AI Player keeper를 선택할 수 없습니다. keeper 목록을 먼저 새로고침하세요.".to_string());
    }

    let model_text = doc
        .get_element_by_id("new-game-models")
        .and_then(|el| el.dyn_ref::<web_sys::HtmlInputElement>().map(|i| i.value()))
        .unwrap_or_default();
    let models = parse_keeper_models(&model_text);

    let mut world_preset_id = doc
        .get_element_by_id("new-game-world-select")
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
        .map(|select| select.value())
        .unwrap_or_default()
        .trim()
        .to_string();
    let mut dm_preset_id = doc
        .get_element_by_id("new-game-dm-preset-select")
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
        .map(|select| select.value())
        .unwrap_or_default()
        .trim()
        .to_string();

    if world_preset_id.is_empty() || dm_preset_id.is_empty() {
        if let Ok((world_options, dm_options)) = refresh_preset_selectors(doc).await {
            if world_preset_id.is_empty() {
                world_preset_id = world_options
                    .first()
                    .map(|row| row.id.clone())
                    .unwrap_or_default();
            }
            if dm_preset_id.is_empty() {
                dm_preset_id = dm_options
                    .first()
                    .map(|row| row.id.clone())
                    .unwrap_or_default();
            }
        }
    }

    if world_preset_id.is_empty() || dm_preset_id.is_empty() {
        let preset_catalog = mcp_tool_call(
            "trpg.preset.list",
            json!({
                "include_characters": false,
                "include_skills": false
            }),
        )
        .await?;
        let preset_catalog = normalize_preset_catalog(&preset_catalog);
        if world_preset_id.is_empty() {
            let world_options = collect_preset_options_from_catalog(
                &preset_catalog,
                &["world_presets", "world", "world_preset", "worlds"],
            );
            world_preset_id = world_options
                .first()
                .map(|row| row.id.clone())
                .or_else(|| extract_first_preset_id(&preset_catalog, "world_presets"))
                .or_else(|| extract_first_preset_id(&preset_catalog, "world"))
                .or_else(|| extract_first_preset_id_by_key(&preset_catalog, "world"))
                .unwrap_or_default();
        }
        if dm_preset_id.is_empty() {
            let dm_options =
                collect_preset_options_from_catalog(&preset_catalog, &["dm_presets", "dm", "dm_preset", "dms"]);
            dm_preset_id = dm_options
                .first()
                .map(|row| row.id.clone())
                .or_else(|| extract_first_preset_id(&preset_catalog, "dm_presets"))
                .or_else(|| extract_first_preset_id(&preset_catalog, "dm"))
                .or_else(|| extract_first_preset_id_by_key(&preset_catalog, "dm"))
                .unwrap_or_default();
        }
    }
    if world_preset_id.is_empty() || dm_preset_id.is_empty() {
        return Err(format!(
            "trpg preset 목록 파싱 실패: world_preset_id={}, dm_preset_id={}",
            world_preset_id, dm_preset_id
        ));
    }

    let party_size = players.len() as i64;
    let pool_size = std::cmp::max(8_i64, party_size);
    let session_id = format!("viewer-{}-{}", room_id, js_sys::Date::now() as i64);

    let pool_result = mcp_tool_call(
        "trpg.pool.generate",
        json!({
            "session_id": session_id,
            "world_preset_id": world_preset_id,
            "dm_preset_id": dm_preset_id,
            "pool_size": pool_size,
            "party_size": party_size,
            "seed": (js_sys::Date::now() as i64) % 100_000
        }),
    )
    .await?;
    let pool = pool_result
        .get("pool")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if pool.is_empty() {
        return Err("pool.generate 결과가 비어 있습니다.".to_string());
    }

    let mut selected_player_ids = pool_result
        .get("suggested_party_ids")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(|id| id.trim().to_string())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    selected_player_ids = unique_non_empty(selected_player_ids);

    if selected_player_ids.len() < party_size as usize {
        for row in &pool {
            let Some(actor_id) = row
                .get("actor_id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|id| !id.is_empty())
            else {
                continue;
            };
            if selected_player_ids.iter().any(|id| id == actor_id) {
                continue;
            }
            selected_player_ids.push(actor_id.to_string());
            if selected_player_ids.len() >= party_size as usize {
                break;
            }
        }
    }
    if selected_player_ids.is_empty() {
        return Err("선택 가능한 actor_id를 찾지 못했습니다.".to_string());
    }

    let party_result = mcp_tool_call(
        "trpg.party.select",
        json!({
            "session_id": session_id,
            "room_id": room_id,
            "pool": pool,
            "selected_player_ids": selected_player_ids
        }),
    )
    .await?;
    let party = party_result
        .get("party")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if party.is_empty() {
        return Err("party.select 결과가 비어 있습니다.".to_string());
    }

    let _start_result = mcp_tool_call(
        "trpg.session.start",
        json!({
            "session_id": session_id,
            "room_id": room_id,
            "dm_preset_id": dm_preset_id,
            "world_preset_id": world_preset_id,
            "party": party,
            "phase": "briefing",
            "force": true
        }),
    )
    .await?;

    let mut actor_ids = party
        .iter()
        .filter_map(|row| row.get("actor_id").and_then(Value::as_str))
        .map(|id| id.trim().to_string())
        .filter(|id| !id.is_empty())
        .collect::<Vec<_>>();
    actor_ids = unique_non_empty(actor_ids);
    if actor_ids.is_empty() {
        return Err("세션 party actor_id를 읽지 못했습니다.".to_string());
    }

    let assignments = assign_keepers_to_actor_ids(&actor_ids, &dm_keeper, &players)?;
    let player_map: std::collections::HashMap<String, String> =
        assignments.into_iter().collect();

    for (actor_id, keeper_name) in &player_map {
        mcp_tool_call(
            "trpg.actor.claim",
            json!({
                "room_id": room_id,
                "actor_id": actor_id,
                "keeper_name": keeper_name
            }),
        )
        .await?;
    }

    let models_value = if models.is_empty() {
        None
    } else {
        Some(Value::Array(
            models
                .iter()
                .map(|m| Value::String(m.clone()))
                .collect::<Vec<_>>(),
        ))
    };

    let mut dm_keeper_up_args = json!({
        "name": dm_keeper,
        "goal": format!("TRPG room {}의 세계관 주민 DM keeper로 장면을 진행하세요.", room_id),
        "instructions": "모든 응답은 한국어로 작성하세요.",
        "proactive_enabled": false,
        "presence_keepalive": true
    });
    if let Some(models_value) = &models_value {
        dm_keeper_up_args["models"] = models_value.clone();
    }
    mcp_tool_call("masc_keeper_up", dm_keeper_up_args)
        .await
        .map_err(|e| {
            format!(
                "DM keeper 준비 실패 ({}): {}. 새 keeper 생성 시 모델 입력이 필요합니다.",
                dm_keeper, e
            )
        })?;

    for (actor_id, keeper_name) in &player_map {
        let mut player_keeper_up_args = json!({
            "name": keeper_name,
            "goal": format!("TRPG room {}에서 {} actor를 플레이하세요.", room_id, actor_id),
            "instructions": "모든 응답은 한국어로 작성하세요.",
            "proactive_enabled": false,
            "presence_keepalive": true
        });
        if let Some(models_value) = &models_value {
            player_keeper_up_args["models"] = models_value.clone();
        }
        mcp_tool_call("masc_keeper_up", player_keeper_up_args)
            .await
            .map_err(|e| {
                format!(
                    "Player keeper 준비 실패 (actor {} / keeper {}): {}. 새 keeper 생성 시 모델 입력이 필요합니다.",
                    actor_id, keeper_name, e
                )
            })?;
    }

    set_current_room_id(doc, &room_id);
    clear_trpg_dom(doc);
    set_round_run_fields(doc, &dm_keeper, &actor_ids, &player_map);
    set_new_game_assignment(
        doc,
        &dm_keeper,
        &dm_preset_id,
        &world_preset_id,
        &player_map,
        &actor_ids,
    );

    Ok(format!(
        "새 게임 시작 완료: room {} / DM {} / players {}{}",
        room_id,
        dm_keeper,
        player_map.len(),
        if auto_selected_players { " (플레이어 자동 선택 적용)" } else { "" }
    ))
}

fn set_new_game_assignment(
    doc: &web_sys::Document,
    dm_keeper: &str,
    dm_preset_id: &str,
    world_preset_id: &str,
    player_map: &std::collections::HashMap<String, String>,
    actor_ids: &[String],
) {
    let Some(el) = doc.get_element_by_id("new-game-assignment") else {
        return;
    };

    let mut html = String::from("<strong>배정 확인</strong><ul>");
    html.push_str(&format!("<li>DM: {}</li>", html_escape(dm_keeper)));
    html.push_str(&format!(
        "<li>Preset: world={} / dm={}</li>",
        html_escape(world_preset_id),
        html_escape(dm_preset_id)
    ));
    for actor_id in actor_ids {
        let keeper = player_map
            .get(actor_id)
            .map(String::as_str)
            .unwrap_or("미정");
        html.push_str(&format!(
            "<li>{} → {}</li>",
            html_escape(actor_id),
            html_escape(keeper)
        ));
    }
    html.push_str("</ul>");
    el.set_inner_html(&html);
}

// ─── Preset System ──────────────────────────────────────────────

fn normalize_preset_catalog(raw: &Value) -> Value {
    let mut value = raw.clone();
    for _ in 0..6 {
        if let Some(next_value) = preset_unwrap_payload(&value) {
            value = next_value;
            continue;
        }
        if let Some(parsed) = preset_unwrap_content(&value) {
            value = parsed;
            continue;
        }
        break;
    }

    if value.is_array() {
        let mut obj = serde_json::Map::new();
        obj.insert("items".to_string(), value);
        return Value::Object(obj);
    }
    if let Some(presets) = value.get("presets") {
        presets.clone()
    } else {
        value
    }
}

fn preset_unwrap_payload(value: &Value) -> Option<Value> {
    value
        .get("payload")
        .or_else(|| value.get("result"))
        .or_else(|| value.get("data"))
        .or_else(|| value.get("structuredContent"))
        .filter(|v| v.is_object())
        .cloned()
        .or_else(|| {
            value
                .get("presets")
                .filter(|v| v.is_object())
                .cloned()
        })
}

fn preset_unwrap_content(value: &Value) -> Option<Value> {
    if let Some(presets_text) = value
        .get("content")
        .and_then(Value::as_array)
        .and_then(|rows| {
            rows.iter().find_map(|row| {
                if row.get("type").and_then(Value::as_str) == Some("text") {
                    row.get("text").and_then(Value::as_str)
                } else {
                    None
                }
            })
        })
    {
        parse_embedded_tool_payload(presets_text).ok()
    } else if let Some(raw_text) = value.get("content").and_then(Value::as_str) {
        parse_embedded_tool_payload(raw_text).ok()
    } else {
        None
    }
}

fn extract_first_preset_id(catalog: &Value, list_key: &str) -> Option<String> {
    catalog
        .get(list_key)
        .and_then(extract_first_preset_id_from_node)
        .or_else(|| catalog.get("items").and_then(extract_first_preset_id_from_node))
        .or_else(|| catalog.get("presets").and_then(extract_first_preset_id_from_node))
        .map(|id| id.trim().to_string())
        .filter(|id| !id.is_empty())
}

fn extract_first_preset_id_from_node(raw: &Value) -> Option<String> {
    if let Some(id) = raw.get("id").and_then(Value::as_str) {
        return Some(id.to_string());
    }
    if let Some(id) = raw
        .get("preset_id")
        .and_then(Value::as_str)
    {
        return Some(id.to_string());
    }
    if let Some(id) = raw.get("uid").and_then(Value::as_str) {
        return Some(id.to_string());
    }
    if let Some(id) = raw.get("name").and_then(Value::as_str) {
        return Some(id.to_string());
    }
    if let Some(items) = raw.get("items").or_else(|| raw.get("presets")) {
        return extract_first_preset_id_from_node(items);
    }
    if let Some(list) = raw.as_array() {
        for item in list {
            if let Some(id) = extract_first_preset_id_from_node(item) {
                return Some(id);
            }
        }
    }
    if let Some(obj) = raw.as_object() {
        for (_, value) in obj {
            if let Some(id) = extract_first_preset_id_from_node(value) {
                return Some(id);
            }
        }
    }
    raw.as_str().map(|raw| raw.to_string())
}

fn extract_first_preset_id_by_key(catalog: &Value, alt_key: &str) -> Option<String> {
    catalog
        .get(alt_key)
        .and_then(Value::as_str)
        .filter(|name| !name.trim().is_empty())
        .map(|name| name.trim().to_string())
}

fn preset_option_from_value(node: &Value) -> Option<PresetOption> {
    let id = node
        .get("id")
        .and_then(Value::as_str)
        .or_else(|| node.get("preset_id").and_then(Value::as_str))
        .or_else(|| node.get("uid").and_then(Value::as_str))
        .or_else(|| node.get("name").and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())?
        .to_string();

    let title = node
        .get("title")
        .and_then(Value::as_str)
        .or_else(|| node.get("label").and_then(Value::as_str))
        .or_else(|| node.get("name").and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(&id)
        .to_string();

    Some(PresetOption { id, title })
}

fn collect_preset_options_from_node(
    node: &Value,
    out: &mut Vec<PresetOption>,
    depth: usize,
) {
    if depth > 6 {
        return;
    }
    match node {
        Value::String(raw) => {
            let value = raw.trim();
            if value.is_empty() {
                return;
            }
            if out.iter().any(|item| item.id == value) {
                return;
            }
            out.push(PresetOption {
                id: value.to_string(),
                title: value.to_string(),
            });
        }
        Value::Array(rows) => {
            for row in rows {
                collect_preset_options_from_node(row, out, depth + 1);
            }
        }
        Value::Object(fields) => {
            if let Some(option) = preset_option_from_value(node) {
                if !out.iter().any(|item| item.id == option.id) {
                    out.push(option);
                }
            }
            for value in fields.values() {
                if value.is_array() || value.is_object() {
                    collect_preset_options_from_node(value, out, depth + 1);
                }
            }
        }
        _ => {}
    }
}

fn collect_preset_options_from_catalog(catalog: &Value, keys: &[&str]) -> Vec<PresetOption> {
    let mut out = Vec::new();
    for key in keys {
        if let Some(node) = catalog.get(*key) {
            collect_preset_options_from_node(node, &mut out, 0);
        }
    }
    if out.is_empty() {
        for fallback_key in ["items", "presets"] {
            if let Some(node) = catalog.get(fallback_key) {
                collect_preset_options_from_node(node, &mut out, 0);
            }
        }
    }
    out
}

fn select_options_set(
    doc: &web_sys::Document,
    select_id: &str,
    options: &[PresetOption],
) -> Option<String> {
    let select = doc
        .get_element_by_id(select_id)
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())?;

    let previous = select.value();
    if options.is_empty() {
        select.set_inner_html(r#"<option value="">(none)</option>"#);
        select.set_value("");
        return None;
    }

    let html = options
        .iter()
        .map(|option| {
            format!(
                r#"<option value="{id}">{title} ({id})</option>"#,
                id = html_escape(&option.id),
                title = html_escape(&option.title),
            )
        })
        .collect::<Vec<_>>()
        .join("");
    select.set_inner_html(&html);

    let selected = if !previous.trim().is_empty()
        && options.iter().any(|option| option.id == previous)
    {
        previous
    } else {
        options[0].id.clone()
    };
    select.set_value(&selected);
    Some(selected)
}

async fn refresh_preset_selectors(
    doc: &web_sys::Document,
) -> Result<(Vec<PresetOption>, Vec<PresetOption>), String> {
    let raw_catalog = mcp_tool_call(
        "trpg.preset.list",
        json!({
            "include_characters": false,
            "include_skills": false
        }),
    )
    .await?;
    let catalog = normalize_preset_catalog(&raw_catalog);

    let world_presets = collect_preset_options_from_catalog(
        &catalog,
        &["world_presets", "world", "world_preset", "worlds"],
    );
    let dm_presets =
        collect_preset_options_from_catalog(&catalog, &["dm_presets", "dm", "dm_preset", "dms"]);

    let _ = select_options_set(doc, "new-game-world-select", &world_presets);
    let _ = select_options_set(doc, "new-game-dm-preset-select", &dm_presets);

    Ok((world_presets, dm_presets))
}

// ─── UI Event Binding ───────────────────────────────────────────

pub(super) fn bind_new_game_controls(doc: &web_sys::Document) {
    let Some(open_btn) = doc.get_element_by_id("new-game-toggle") else {
        return;
    };
    if open_btn.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = open_btn.set_attribute("data-bound", "1");

    let open_cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        set_element_display(&doc, "new-game-panel", "flex");
        if let Some(room_input) = doc
            .get_element_by_id("new-game-room-id")
            .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
        {
            if room_input.value().trim().is_empty() {
                room_input.set_value(&generate_room_id());
            }
        }
        set_new_game_status(&doc, "Keeper 목록을 불러오는 중...");
        set_new_game_preflight_status(&doc, "사전 점검 준비 중...");
        actor_admin_set_status(&doc, "액터 목록을 불러오는 중...", "status-info");
        let doc_for_fetch = doc.clone();
        wasm_bindgen_futures::spawn_local(async move {
            match refresh_new_game_bootstrap(&doc_for_fetch).await {
                Ok(bootstrap) => {
                    set_new_game_status(
                        &doc_for_fetch,
                        &format!(
                            "Keeper {}개 · 월드 {}개 · DM 프리셋 {}개 로드됨",
                            bootstrap.keepers.len(),
                            bootstrap.world_presets.len(),
                            bootstrap.dm_presets.len()
                        ),
                    );
                    actor_admin_set_status(&doc_for_fetch, "액터 목록 로드 완료", "status-ok");
                    set_new_game_preflight_status(&doc_for_fetch, "사전 점검 실행 중...");
                    let _ = run_new_game_preflight(&doc_for_fetch).await;
                }
                Err(e) => {
                    web_sys::console::error_1(&format!("[bind_new_game_controls] bootstrap FAILED: {}", e).into());
                    set_new_game_status(&doc_for_fetch, &format!("초기 로드 실패: {}", e));
                    actor_admin_set_status(&doc_for_fetch, &format!("로드 실패: {}", e), "status-error");
                    set_new_game_preflight_status(
                        &doc_for_fetch,
                        &format!("사전 점검 불가: {}", e),
                    );
                }
            }
        });
    }) as Box<dyn FnMut()>);
    let _ = open_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
        target.add_event_listener_with_callback("click", open_cb.as_ref().unchecked_ref())
    });
    open_cb.forget();

    if let Some(close_btn) = doc.get_element_by_id("new-game-close") {
        let close_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            set_element_display(&doc, "new-game-panel", "none");
        }) as Box<dyn FnMut()>);
        let _ = close_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", close_cb.as_ref().unchecked_ref())
        });
        close_cb.forget();
    }

    if let Some(regen_btn) = doc.get_element_by_id("new-game-room-regenerate") {
        let regen_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            if let Some(room_input) = doc
                .get_element_by_id("new-game-room-id")
                .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
            {
                room_input.set_value(&generate_room_id());
            }
        }) as Box<dyn FnMut()>);
        let _ = regen_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", regen_cb.as_ref().unchecked_ref())
        });
        regen_cb.forget();
    }

    if let Some(refresh_btn) = doc.get_element_by_id("new-game-refresh") {
        let refresh_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            set_new_game_status(&doc, "세션/프리셋/keeper 정보를 새로고침 중...");
            set_new_game_preflight_status(&doc, "사전 점검 실행 중...");
            actor_admin_set_status(&doc, "액터 목록 새로고침 중...", "status-info");
            let doc_for_fetch = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                match refresh_new_game_bootstrap(&doc_for_fetch).await {
                    Ok(bootstrap) => {
                        set_new_game_status(
                            &doc_for_fetch,
                            &format!(
                                "Keeper {}개 · 월드 {}개 · DM 프리셋 {}개 새로고침 완료",
                                bootstrap.keepers.len(),
                                bootstrap.world_presets.len(),
                                bootstrap.dm_presets.len()
                            ),
                        );
                        actor_admin_set_status(&doc_for_fetch, "액터 목록 새로고침 완료", "status-ok");
                        let _ = run_new_game_preflight(&doc_for_fetch).await;
                    }
                    Err(e) => {
                        set_new_game_status(&doc_for_fetch, &format!("새로고침 실패: {}", e));
                        actor_admin_set_status(&doc_for_fetch, &format!("새로고침 실패: {}", e), "status-error");
                        set_new_game_preflight_status(
                            &doc_for_fetch,
                            &format!("사전 점검 실패: {}", e),
                        );
                    }
                }
            });
        }) as Box<dyn FnMut()>);
        let _ = refresh_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", refresh_cb.as_ref().unchecked_ref())
        });
        refresh_cb.forget();
    }

    if let Some(preflight_btn) = doc.get_element_by_id("new-game-preflight-btn") {
        let preflight_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            set_new_game_preflight_status(&doc, "사전 점검 실행 중...");
            let doc_for_task = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                if let Err(err) = run_new_game_preflight(&doc_for_task).await {
                    log::warn!("new-game preflight failed: {}", err);
                }
            });
        }) as Box<dyn FnMut()>);
        let _ = preflight_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", preflight_cb.as_ref().unchecked_ref())
        });
        preflight_cb.forget();
    }

    if let Some(start_btn) = doc.get_element_by_id("new-game-start") {
        let start_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            set_new_game_status(&doc, "새 게임 시작 중...");
            if let Some(btn) = doc.get_element_by_id("new-game-start") {
                let _ = btn.set_attribute("disabled", "true");
            }
            let doc_for_start = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                let result = start_new_game_flow(&doc_for_start).await;
                match result {
                    Ok(message) => {
                        set_new_game_status(&doc_for_start, &message);
                        set_element_display(&doc_for_start, "new-game-panel", "none");
                    }
                    Err(e) => {
                        set_new_game_status(&doc_for_start, &format!("시작 실패: {}", e));
                    }
                }
                if let Some(btn) = doc_for_start.get_element_by_id("new-game-start") {
                    let _ = btn.remove_attribute("disabled");
                }
            });
        }) as Box<dyn FnMut()>);
        let _ = start_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", start_cb.as_ref().unchecked_ref())
        });
        start_cb.forget();
    }

    bind_actor_admin_controls(doc);
}

fn bind_actor_admin_controls(doc: &web_sys::Document) {
    let Some(refresh_btn) = doc.get_element_by_id("actor-admin-refresh") else {
        return;
    };
    if refresh_btn.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = refresh_btn.set_attribute("data-bound", "1");

    let refresh_cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        actor_admin_set_busy(&doc, true);
        actor_admin_set_status(&doc, "액터 목록을 불러오는 중...", "status-info");
        let doc_for_task = doc.clone();
        wasm_bindgen_futures::spawn_local(async move {
            let result = refresh_actor_admin_list(&doc_for_task).await;
            match result {
                Ok(rows) => actor_admin_set_status(
                    &doc_for_task,
                    &format!(
                        "room {} 액터 {}명",
                        html_escape(&actor_admin_room_id()),
                        rows.len()
                    ),
                    "status-ok",
                ),
                Err(e) => actor_admin_set_status(
                    &doc_for_task,
                    &format!("액터 목록 조회 실패: {}", e),
                    "status-error",
                ),
            }
            actor_admin_set_busy(&doc_for_task, false);
        });
    }) as Box<dyn FnMut()>);
    let _ = refresh_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
        target.add_event_listener_with_callback("click", refresh_cb.as_ref().unchecked_ref())
    });
    refresh_cb.forget();

    if let Some(spawn_btn) = doc.get_element_by_id("actor-admin-spawn") {
        let spawn_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            actor_admin_set_busy(&doc, true);
            actor_admin_set_status(&doc, "액터 생성 중...", "status-info");
            let doc_for_task = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                let result = actor_admin_spawn(&doc_for_task).await;
                match result {
                    Ok(msg) => actor_admin_set_status(&doc_for_task, &msg, "status-ok"),
                    Err(e) => actor_admin_set_status(
                        &doc_for_task,
                        &format!("액터 생성 실패: {}", e),
                        "status-error",
                    ),
                }
                actor_admin_set_busy(&doc_for_task, false);
            });
        }) as Box<dyn FnMut()>);
        let _ = spawn_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", spawn_cb.as_ref().unchecked_ref())
        });
        spawn_cb.forget();
    }

    if let Some(update_btn) = doc.get_element_by_id("actor-admin-update") {
        let update_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            actor_admin_set_busy(&doc, true);
            actor_admin_set_status(&doc, "액터 수정 중...", "status-info");
            let doc_for_task = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                let result = actor_admin_update(&doc_for_task).await;
                match result {
                    Ok(msg) => actor_admin_set_status(&doc_for_task, &msg, "status-ok"),
                    Err(e) => actor_admin_set_status(
                        &doc_for_task,
                        &format!("액터 수정 실패: {}", e),
                        "status-error",
                    ),
                }
                actor_admin_set_busy(&doc_for_task, false);
            });
        }) as Box<dyn FnMut()>);
        let _ = update_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", update_cb.as_ref().unchecked_ref())
        });
        update_cb.forget();
    }

    if let Some(delete_btn) = doc.get_element_by_id("actor-admin-delete") {
        let delete_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            let actor_id = actor_admin_input_value(&doc, "actor-admin-id");
            if actor_id.is_empty() {
                actor_admin_set_status(&doc, "삭제할 Actor ID를 입력하세요.", "status-error");
                return;
            }
            let confirmed = web_sys::window()
                .and_then(|w| {
                    w.confirm_with_message(&format!("actor {} 를 삭제할까요?", actor_id))
                        .ok()
                })
                .unwrap_or(false);
            if !confirmed {
                return;
            }
            actor_admin_set_busy(&doc, true);
            actor_admin_set_status(&doc, "액터 삭제 중...", "status-info");
            let doc_for_task = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                let result = actor_admin_delete(&doc_for_task).await;
                match result {
                    Ok(msg) => actor_admin_set_status(&doc_for_task, &msg, "status-ok"),
                    Err(e) => actor_admin_set_status(
                        &doc_for_task,
                        &format!("액터 삭제 실패: {}", e),
                        "status-error",
                    ),
                }
                actor_admin_set_busy(&doc_for_task, false);
            });
        }) as Box<dyn FnMut()>);
        let _ = delete_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", delete_cb.as_ref().unchecked_ref())
        });
        delete_cb.forget();
    }
}

// ─── Widget Status ──────────────────────────────────────────────

pub(super) fn refresh_trpg_widget_status() {
    fn parse_counter_attr(doc: &web_sys::Document, key: &str) -> u64 {
        doc.get_element_by_id("dashboard")
            .and_then(|el| el.get_attribute(key))
            .and_then(|raw| raw.parse::<u64>().ok())
            .unwrap_or(0)
    }

    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let narrative_count = doc
        .get_element_by_id("narrative-log")
        .map(|el| el.child_element_count())
        .unwrap_or(0);
    let party_count = doc
        .get_element_by_id("character-panel")
        .map(|el| el.child_element_count())
        .unwrap_or(0);
    let history_count = doc
        .get_element_by_id("session-history")
        .map(|el| el.child_element_count())
        .unwrap_or(0);
    if let Some(status) = doc.get_element_by_id("widget-status") {
        status.set_text_content(Some(&format!(
            "Widgets N:{} P:{} H:{}",
            narrative_count, party_count, history_count
        )));
    }
    let dedup_stream = parse_counter_attr(&doc, "data-dedup-stream");
    let dedup_narrative = parse_counter_attr(&doc, "data-dedup-narrative");
    let dedup_history = parse_counter_attr(&doc, "data-dedup-history");
    if let Some(status) = doc.get_element_by_id("dedup-status") {
        status.set_text_content(Some(&format!(
            "Dedup S:{} N:{} H:{}",
            dedup_stream, dedup_narrative, dedup_history
        )));
    }
    let popover_visible = doc
        .get_element_by_id("dedup-status")
        .and_then(|el| el.get_attribute("aria-expanded"))
        .map(|v| v == "true")
        .unwrap_or(false);
    if popover_visible {
        render_dedup_popover(&doc);
    }
}
