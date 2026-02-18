//! Room hub — room management, local-storage persistence, and room-selector UI.

use serde_json::{json, Value};
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use wasm_bindgen_futures::JsFuture;

use crate::dom::escape::html_escape;
use crate::game::lifecycle::TrpgLifecycleState;

use super::mcp_rpc::mcp_tool_call;
use super::{
    actor_admin_room_id, actor_admin_set_status, clear_trpg_dom, refresh_actor_admin_list,
    set_current_room_id, set_element_display, unique_non_empty,
};

const RECENT_ROOMS_STORAGE_KEY: &str = "masc_viewer_recent_rooms";
pub(super) const KNOWN_ROOMS_STORAGE_KEY: &str = "masc_viewer_known_rooms";
pub(super) const ROOM_HUB_VISIBLE_STORAGE_KEY: &str = "masc_viewer_room_hub_visible";
pub(super) const ROOM_HUB_RUNNING_ONLY_STORAGE_KEY: &str = "masc_viewer_room_hub_running_only";

pub(super) fn load_recent_rooms() -> Vec<String> {
    let raw = web_sys::window()
        .and_then(|w| w.local_storage().ok().flatten())
        .and_then(|storage| storage.get_item(RECENT_ROOMS_STORAGE_KEY).ok().flatten())
        .unwrap_or_default();
    unique_non_empty(
        raw.split('\n')
            .filter_map(crate::config::sanitize_room_id)
            .collect::<Vec<_>>(),
    )
}

fn save_recent_rooms(rooms: &[String]) {
    let value = rooms.join("\n");
    if let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten()) {
        let _ = storage.set_item(RECENT_ROOMS_STORAGE_KEY, &value);
    }
}

pub(super) fn remember_recent_room(room_id: &str) {
    let Some(room) = crate::config::sanitize_room_id(room_id) else {
        return;
    };
    let mut rooms = load_recent_rooms();
    rooms.retain(|existing| existing != &room);
    rooms.insert(0, room);
    if rooms.len() > 12 {
        rooms.truncate(12);
    }
    save_recent_rooms(&rooms);
}

#[derive(Debug, Clone)]
pub(super) struct RoomSnapshot {
    pub(super) id: String,
    pub(super) status: String,
    pub(super) turn: u32,
    pub(super) phase: String,
    pub(super) agent_count: i64,
    pub(super) task_count: i64,
}

pub(super) fn room_lane_label(status: &str) -> &'static str {
    TrpgLifecycleState::from_status(status).lane()
}

fn render_room_hub(doc: &web_sys::Document, rooms: &[RoomSnapshot], selected_room: &str) {
    let Some(hub) = doc.get_element_by_id("room-hub") else {
        return;
    };
    let running_only = load_room_hub_running_only();
    let mut running = Vec::new();
    let mut stopped = Vec::new();
    let mut lobby = Vec::new();
    let mut unavailable = Vec::new();
    let mut ended = Vec::new();

    for room in rooms {
        let lane = room_lane_label(&room.status);
        let current_attr = if room.id == selected_room {
            " data-current=\"1\""
        } else {
            " data-current=\"0\""
        };
        let status_text = if room.status.trim().is_empty() {
            "unknown".to_string()
        } else {
            room.status.clone()
        };
        let lifecycle = TrpgLifecycleState::from_status(&status_text);
        let card = format!(
            concat!(
                "<button class=\"room-chip\" data-room-id=\"{id}\" data-room-status=\"{status}\"{current}>",
                "<span class=\"room-chip-id\">{id}<span class=\"room-chip-state {state_class}\">{state_label}</span></span>",
                "<span class=\"room-chip-meta\">turn {turn} · {phase} · a{agents}/t{tasks}</span>",
                "</button>"
            ),
            id = html_escape(&room.id),
            status = html_escape(&status_text),
            current = current_attr,
            state_class = lifecycle.css_class(),
            state_label = lifecycle.label_ko(),
            turn = room.turn,
            phase = html_escape(&room.phase),
            agents = room.agent_count,
            tasks = room.task_count
        );
        match lane {
            "running" => running.push(card),
            "stopped" => stopped.push(card),
            "unavailable" => unavailable.push(card),
            "ended" => ended.push(card),
            _ => lobby.push(card),
        }
    }

    let lane_html = |title: &str, rows: Vec<String>, lane: &str| -> String {
        let body = if rows.is_empty() {
            "<div class=\"room-chip-empty\">(없음)</div>".to_string()
        } else {
            rows.join("")
        };
        format!(
            "<div class=\"room-lane\" data-lane=\"{lane}\"><div class=\"room-lane-title\">{title}</div><div class=\"room-chip-list\">{body}</div></div>",
            lane = lane,
            title = title,
            body = body
        )
    };

    let lanes_html = if running_only {
        lane_html("진행 중", running, "running")
    } else {
        format!(
            "{}{}{}{}{}",
            lane_html("진행 중", running, "running"),
            lane_html("멈춤", stopped, "stopped"),
            lane_html("로비", lobby, "lobby"),
            lane_html("오류", unavailable, "unavailable"),
            lane_html("종료", ended, "ended")
        )
    };
    let html = format!(
        concat!(
            "<div class=\"room-hub-tools\">",
            "<button id=\"room-hub-running-toggle\" class=\"room-hub-filter\" type=\"button\" aria-pressed=\"{pressed}\">",
            "진행 중만",
            "</button>",
            "</div>",
            "{lanes}"
        ),
        pressed = if running_only { "true" } else { "false" },
        lanes = lanes_html
    );
    let _ = hub.set_attribute("data-running-only", if running_only { "1" } else { "0" });
    hub.set_inner_html(&html);
}

fn bind_room_hub_buttons(doc: &web_sys::Document) {
    if let Ok(nodes) = doc.query_selector_all("#room-hub .room-chip") {
        for i in 0..nodes.length() {
            let Some(node) = nodes.item(i) else { continue };
            let Some(el) = node.dyn_ref::<web_sys::Element>() else {
                continue;
            };
            if el.get_attribute("data-bound").as_deref() == Some("1") {
                continue;
            }
            let Some(room_id) = el.get_attribute("data-room-id") else {
                continue;
            };
            let _ = el.set_attribute("data-bound", "1");
            let room_copy = room_id.clone();
            let cb = Closure::wrap(Box::new(move || {
                let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                    return;
                };
                apply_room_switch_from_ui(&doc, &room_copy);
            }) as Box<dyn FnMut()>);
            let _ = el.dyn_ref::<web_sys::EventTarget>().map(|target| {
                target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
            });
            cb.forget();
        }
    }

    if let Some(toggle) = doc.get_element_by_id("room-hub-running-toggle") {
        if toggle.get_attribute("data-bound").as_deref() != Some("1") {
            let _ = toggle.set_attribute("data-bound", "1");
            let cb = Closure::wrap(Box::new(move || {
                let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                    return;
                };
                let pressed = doc
                    .get_element_by_id("room-hub-running-toggle")
                    .and_then(|el| el.get_attribute("aria-pressed"))
                    .map(|v| v == "true")
                    .unwrap_or(false);
                save_room_hub_running_only(!pressed);
                let doc_for_fetch = doc.clone();
                wasm_bindgen_futures::spawn_local(async move {
                    let _ = refresh_rooms_from_server(&doc_for_fetch).await;
                });
            }) as Box<dyn FnMut()>);
            let _ = toggle.dyn_ref::<web_sys::EventTarget>().map(|target| {
                target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
            });
            cb.forget();
        }
    }
}

fn sync_room_hub_selection(doc: &web_sys::Document, selected_room: &str) {
    let Ok(nodes) = doc.query_selector_all("#room-hub .room-chip") else {
        return;
    };
    for i in 0..nodes.length() {
        let Some(node) = nodes.item(i) else { continue };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };
        let room = el.get_attribute("data-room-id").unwrap_or_default();
        let current = if room == selected_room { "1" } else { "0" };
        let _ = el.set_attribute("data-current", current);
    }
}

async fn fetch_room_runtime(room_id: &str) -> Result<(String, u32, String), String> {
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
    let json: Value =
        serde_json::from_str(&body).map_err(|e| format!("state JSON 파싱 실패: {}", e))?;

    let room = json.get("room").unwrap_or(&Value::Null);
    let state = json.get("state").unwrap_or(&Value::Null);

    let mut status = room
        .get("status")
        .and_then(Value::as_str)
        .or_else(|| state.get("status").and_then(Value::as_str))
        .unwrap_or("idle")
        .to_string();
    let turn = room
        .get("turn")
        .and_then(Value::as_u64)
        .or_else(|| state.get("turn").and_then(Value::as_u64))
        .unwrap_or(0) as u32;
    let phase = room
        .get("phase")
        .and_then(Value::as_str)
        .or_else(|| state.get("phase").and_then(Value::as_str))
        .unwrap_or("-")
        .to_string();

    // Staleness detection: override "active" to "paused" when last event is old
    if status == "active" {
        let last_event_ts = state
            .get("last_event_ts")
            .and_then(Value::as_str)
            .unwrap_or("");
        if !last_event_ts.is_empty() {
            let event_ms = js_sys::Date::parse(last_event_ts);
            if event_ms.is_finite() {
                let now_ms = js_sys::Date::now();
                let elapsed_sec = (now_ms - event_ms) / 1000.0;
                // 30 minutes without any event → stale game
                if elapsed_sec > 1800.0 {
                    status = "paused".to_string();
                }
            }
        }
    }

    Ok((status, turn, phase))
}

fn load_known_rooms() -> Vec<String> {
    let raw = web_sys::window()
        .and_then(|w| w.local_storage().ok().flatten())
        .and_then(|storage| storage.get_item(KNOWN_ROOMS_STORAGE_KEY).ok().flatten())
        .unwrap_or_default();
    unique_non_empty(
        raw.split('\n')
            .filter_map(crate::config::sanitize_room_id)
            .collect::<Vec<_>>(),
    )
}

fn save_known_rooms(rooms: &[String]) {
    let value = rooms.join("\n");
    if let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten()) {
        let _ = storage.set_item(KNOWN_ROOMS_STORAGE_KEY, &value);
    }
}

fn load_room_hub_visible() -> bool {
    web_sys::window()
        .and_then(|w| w.local_storage().ok().flatten())
        .and_then(|storage| {
            storage
                .get_item(ROOM_HUB_VISIBLE_STORAGE_KEY)
                .ok()
                .flatten()
        })
        .map(|value| matches!(value.trim(), "1" | "true" | "on"))
        .unwrap_or(false)
}

fn save_room_hub_visible(visible: bool) {
    if let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten()) {
        let _ = storage.set_item(
            ROOM_HUB_VISIBLE_STORAGE_KEY,
            if visible { "1" } else { "0" },
        );
    }
}

fn load_room_hub_running_only() -> bool {
    web_sys::window()
        .and_then(|w| w.local_storage().ok().flatten())
        .and_then(|storage| {
            storage
                .get_item(ROOM_HUB_RUNNING_ONLY_STORAGE_KEY)
                .ok()
                .flatten()
        })
        .map(|value| matches!(value.trim(), "1" | "true" | "on"))
        .unwrap_or(false)
}

fn save_room_hub_running_only(enabled: bool) {
    if let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten()) {
        let _ = storage.set_item(
            ROOM_HUB_RUNNING_ONLY_STORAGE_KEY,
            if enabled { "1" } else { "0" },
        );
    }
}

fn set_room_hub_visible(doc: &web_sys::Document, visible: bool) {
    set_element_display(doc, "room-hub", if visible { "grid" } else { "none" });
    if let Some(toggle) = doc.get_element_by_id("room-hub-toggle") {
        let _ = toggle.set_attribute("aria-pressed", if visible { "true" } else { "false" });
        toggle.set_text_content(Some(if visible { "방 목록 닫기" } else { "방 목록" }));
    }
}

fn remember_known_rooms(extra_rooms: &[String]) {
    let mut rooms = load_known_rooms();
    for raw in extra_rooms {
        let Some(room) = crate::config::sanitize_room_id(raw) else {
            continue;
        };
        if rooms.iter().any(|existing| existing == &room) {
            continue;
        }
        rooms.push(room);
    }
    rooms = unique_non_empty(rooms);
    if rooms.len() > 64 {
        rooms = rooms.split_off(rooms.len() - 64);
    }
    save_known_rooms(&rooms);
}

pub(super) fn sync_room_controls(doc: &web_sys::Document, selected_room: &str) {
    let selected = crate::config::sanitize_room_id(selected_room)
        .unwrap_or_else(|| crate::config::DEFAULT_ROOM_ID.to_string());
    let mut rooms = vec![selected.clone(), crate::config::DEFAULT_ROOM_ID.to_string()];
    rooms.extend(load_known_rooms());
    rooms.extend(load_recent_rooms());
    let rooms = unique_non_empty(rooms);

    if let Some(select) = doc
        .get_element_by_id("room-selector-inline")
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
    {
        let html = rooms
            .iter()
            .map(|room| {
                let safe = html_escape(room);
                format!(r#"<option value="{safe}">{safe}</option>"#)
            })
            .collect::<Vec<_>>()
            .join("");
        select.set_inner_html(&html);
        select.set_value(&selected);
    }
    if let Some(input) = doc
        .get_element_by_id("room-input-inline")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_value(&selected);
    }
    if let Some(pill) = doc.get_element_by_id("room-status") {
        let lifecycle = TrpgLifecycleState::Lobby;
        pill.set_text_content(Some(&format!(
            "현재 방: {} · {}",
            selected,
            lifecycle.label_ko()
        )));
        let _ = pill.set_attribute("data-lifecycle", lifecycle.css_class());
        let _ = pill.set_attribute("title", lifecycle.help_text());
    }
    sync_room_hub_selection(doc, &selected);
}

fn apply_room_switch_from_ui(doc: &web_sys::Document, raw_room: &str) {
    let Some(room) = crate::config::sanitize_room_id(raw_room) else {
        log::warn!("Ignoring invalid room id from UI: {}", raw_room);
        return;
    };
    remember_known_rooms(std::slice::from_ref(&room));
    set_current_room_id(doc, &room);
    clear_trpg_dom(doc);
    sync_room_hub_selection(doc, &room);
    let doc_for_refresh = doc.clone();
    wasm_bindgen_futures::spawn_local(async move {
        if let Ok(rows) = refresh_actor_admin_list(&doc_for_refresh).await {
            actor_admin_set_status(
                &doc_for_refresh,
                &format!("room {} 액터 {}명", actor_admin_room_id(), rows.len()),
                "status-ok",
            );
        }
    });
    log::info!("Viewer room switched to {}", room);
}

pub(super) async fn refresh_rooms_from_server(doc: &web_sys::Document) -> Result<Vec<RoomSnapshot>, String> {
    let payload = mcp_tool_call("masc_rooms_list", json!({})).await?;

    let mut snapshots = payload
        .get("rooms")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|row| {
                    let id = row
                        .get("id")
                        .and_then(Value::as_str)
                        .or_else(|| row.as_str())
                        .map(str::trim)
                        .filter(|id| !id.is_empty())?;
                    let agent_count = row.get("agent_count").and_then(Value::as_i64).unwrap_or(0);
                    let task_count = row.get("task_count").and_then(Value::as_i64).unwrap_or(0);
                    Some(RoomSnapshot {
                        id: id.to_string(),
                        status: "idle".to_string(),
                        turn: 0,
                        phase: "-".to_string(),
                        agent_count,
                        task_count,
                    })
                })
                .collect::<Vec<RoomSnapshot>>()
        })
        .unwrap_or_default();

    if let Some(current) = payload
        .get("current_room")
        .and_then(Value::as_str)
        .map(str::to_string)
    {
        if !snapshots.iter().any(|row| row.id == current) {
            snapshots.push(RoomSnapshot {
                id: current,
                status: "idle".to_string(),
                turn: 0,
                phase: "-".to_string(),
                agent_count: 0,
                task_count: 0,
            });
        }
    }

    let room_ids = unique_non_empty(
        snapshots
            .iter()
            .map(|row| row.id.clone())
            .collect::<Vec<_>>(),
    );
    if room_ids.is_empty() {
        return Err("서버 room 목록이 비어 있습니다.".to_string());
    }

    for row in &mut snapshots {
        match fetch_room_runtime(&row.id).await {
            Ok((status, turn, phase)) => {
                row.status = status;
                row.turn = turn;
                row.phase = phase;
            }
            Err(e) => {
                row.status = "unknown".to_string();
                row.phase = format!("error: {}", e);
            }
        }
    }

    remember_known_rooms(&room_ids);
    let current = crate::config::current_room_id();
    sync_room_controls(doc, &current);
    render_room_hub(doc, &snapshots, &current);
    bind_room_hub_buttons(doc);
    Ok(snapshots)
}

pub(super) fn bind_room_controls(doc: &web_sys::Document) {
    let Some(select_el) = doc.get_element_by_id("room-selector-inline") else {
        return;
    };
    let room_now = crate::config::current_room_id();
    sync_room_controls(doc, &room_now);
    set_room_hub_visible(doc, load_room_hub_visible());

    if select_el.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = select_el.set_attribute("data-bound", "1");

    let select_cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let selected = doc
            .get_element_by_id("room-selector-inline")
            .and_then(|el| {
                el.dyn_ref::<web_sys::HtmlSelectElement>()
                    .map(|s| s.value())
            })
            .unwrap_or_default();
        if selected.trim().is_empty() {
            return;
        }
        apply_room_switch_from_ui(&doc, &selected);
    }) as Box<dyn FnMut()>);
    let _ = select_el.dyn_ref::<web_sys::EventTarget>().map(|target| {
        target.add_event_listener_with_callback("change", select_cb.as_ref().unchecked_ref())
    });
    select_cb.forget();

    if let Some(apply_btn) = doc.get_element_by_id("room-apply-btn") {
        let apply_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            let typed = doc
                .get_element_by_id("room-input-inline")
                .and_then(|el| el.dyn_ref::<web_sys::HtmlInputElement>().map(|i| i.value()))
                .unwrap_or_default();
            apply_room_switch_from_ui(&doc, &typed);
        }) as Box<dyn FnMut()>);
        let _ = apply_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", apply_cb.as_ref().unchecked_ref())
        });
        apply_cb.forget();
    }

    if let Some(input_el) = doc.get_element_by_id("room-input-inline") {
        let key_cb = Closure::wrap(Box::new(move |event: web_sys::KeyboardEvent| {
            if event.key() != "Enter" {
                return;
            }
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            let typed = doc
                .get_element_by_id("room-input-inline")
                .and_then(|el| el.dyn_ref::<web_sys::HtmlInputElement>().map(|i| i.value()))
                .unwrap_or_default();
            apply_room_switch_from_ui(&doc, &typed);
        }) as Box<dyn FnMut(web_sys::KeyboardEvent)>);
        let _ = input_el.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("keydown", key_cb.as_ref().unchecked_ref())
        });
        key_cb.forget();
    }

    if let Some(refresh_btn) = doc.get_element_by_id("room-refresh-btn") {
        let refresh_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            if let Some(pill) = doc.get_element_by_id("room-status") {
                let current = crate::config::current_room_id();
                pill.set_text_content(Some(&format!("현재 방: {} · 목록 불러오는 중...", current)));
            }
            let doc_for_fetch = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                match refresh_rooms_from_server(&doc_for_fetch).await {
                    Ok(rooms) => {
                        let current = crate::config::current_room_id();
                        if let Some(pill) = doc_for_fetch.get_element_by_id("room-status") {
                            pill.set_text_content(Some(&format!(
                                "현재 방: {} · {}개 방",
                                current,
                                rooms.len()
                            )));
                        }
                    }
                    Err(e) => {
                        log::warn!("room 목록 새로고침 실패: {}", e);
                        let current = crate::config::current_room_id();
                        if let Some(pill) = doc_for_fetch.get_element_by_id("room-status") {
                            pill.set_text_content(Some(&format!(
                                "현재 방: {} · 목록 실패",
                                current
                            )));
                        }
                    }
                }
            });
        }) as Box<dyn FnMut()>);
        let _ = refresh_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", refresh_cb.as_ref().unchecked_ref())
        });
        refresh_cb.forget();
    }

    if let Some(hub_toggle) = doc.get_element_by_id("room-hub-toggle") {
        let hub_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            let visible = doc
                .get_element_by_id("room-hub-toggle")
                .and_then(|el| el.get_attribute("aria-pressed"))
                .map(|v| v == "true")
                .unwrap_or(false);
            let next = !visible;
            set_room_hub_visible(&doc, next);
            save_room_hub_visible(next);
        }) as Box<dyn FnMut()>);
        let _ = hub_toggle.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", hub_cb.as_ref().unchecked_ref())
        });
        hub_cb.forget();
    }
}

pub(super) fn parse_keeper_models(raw: &str) -> Vec<String> {
    unique_non_empty(
        raw.split(',')
            .map(|part| part.trim().to_string())
            .collect::<Vec<_>>(),
    )
}

pub(super) fn selected_player_keepers(doc: &web_sys::Document) -> Vec<String> {
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
