//! TRPG session timeline.
//!
//! Captures narrative, dice, and turn-progress events into per-room,
//! per-turn history and renders them as a compact browser.

#![allow(dead_code)] // Many helpers used only in wasm32 cfg blocks.

use bevy::prelude::*;
use std::cmp::Ordering;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::closure::Closure;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;

use crate::game::events::{DiceRolled, NarrativeReceived, TurnAdvanced, TurnProgressUpdated};
use crate::game::state::{RoomState, TurnProgressState};

const MAX_ROOMS_TO_KEEP: usize = 24;
const MAX_TURNS_TO_KEEP: usize = 24;
const MAX_EVENTS_PER_TURN: usize = 80;

#[derive(Clone, Debug, PartialEq)]
struct HistoryEvent {
    kind: String,
    actor: String,
    title: String,
    detail: String,
}

#[derive(Clone, Debug, PartialEq)]
struct TurnHistory {
    turn: u32,
    phase: String,
    events: Vec<HistoryEvent>,
}

#[derive(Clone, Debug, PartialEq)]
struct RoomHistory {
    room_id: String,
    status: String,
    turns: Vec<TurnHistory>,
    updated_turn: u32,
}

#[derive(Resource, Default)]
pub struct SessionHistoryCache {
    rooms: Vec<RoomHistory>,
}

#[cfg(target_arch = "wasm32")]
use super::escape::{html_escape, sanitize_text};

fn sanitize_key(raw: &str) -> String {
    raw.trim().to_ascii_lowercase()
}

fn normalize_room_id(raw: &str) -> String {
    let normalized = crate::config::sanitize_room_id(raw)
        .unwrap_or_else(|| raw.trim().to_string())
        .trim()
        .to_ascii_lowercase();
    if normalized.is_empty() {
        "room-unknown".to_string()
    } else {
        normalized
    }
}

fn normalize_room_status(raw: &str) -> String {
    let key = sanitize_key(raw);
    match key.as_str() {
        "active" | "running" | "started" | "in_progress" | "in-progress" | "playing" | "open" => {
            "active"
        }
        "paused" | "pause" | "stopped" | "on_hold" | "on-hold" => "paused",
        "idle" | "lobby" | "created" | "ready" => "unknown",
        "ended" | "finished" | "completed" | "closed" | "done" | "archived" | "terminated" => {
            "ended"
        }
        _ => "unknown",
    }
    .to_string()
}

fn room_status_bucket(status: &str) -> u8 {
    match normalize_room_status(status).as_str() {
        "active" => 0,
        "paused" => 1,
        "ended" => 2,
        _ => 3,
    }
}

fn room_status_label_ko(status: &str) -> &'static str {
    match normalize_room_status(status).as_str() {
        "active" => "진행중",
        "paused" => "멈춤",
        "ended" => "종료",
        _ => "기타",
    }
}

fn room_status_class(status: &str) -> &'static str {
    match normalize_room_status(status).as_str() {
        "active" => "active",
        "paused" => "paused",
        "ended" => "ended",
        _ => "unknown",
    }
}

fn compare_room_priority(a: &RoomHistory, b: &RoomHistory) -> Ordering {
    room_status_bucket(&a.status)
        .cmp(&room_status_bucket(&b.status))
        .then_with(|| b.updated_turn.cmp(&a.updated_turn))
        .then_with(|| a.room_id.cmp(&b.room_id))
}

fn history_kind_class(kind: &str) -> &'static str {
    match kind {
        "dice" => "kind-dice",
        "turn" => "kind-turn",
        "progress" => "kind-progress",
        "system" => "kind-system",
        "narrative" => "kind-narrative",
        _ => "kind-narrative",
    }
}

fn ensure_turn_entry(turns: &mut Vec<TurnHistory>, turn: u32, phase: &str) -> (usize, bool) {
    let normalized_turn = turn.max(1);
    for (idx, row) in turns.iter_mut().enumerate() {
        if row.turn == normalized_turn {
            let mut changed = false;
            if !phase.trim().is_empty() && row.phase != phase {
                row.phase = phase.to_string();
                changed = true;
            }
            return (idx, changed);
        }
    }

    turns.push(TurnHistory {
        turn: normalized_turn,
        phase: phase.to_string(),
        events: Vec::new(),
    });
    turns.sort_by_key(|row| row.turn);

    while turns.len() > MAX_TURNS_TO_KEEP {
        let _ = turns.remove(0);
    }

    let idx = turns
        .iter()
        .position(|row| row.turn == normalized_turn)
        .unwrap_or(0);
    (idx, true)
}

fn ensure_room_entry(
    rooms: &mut Vec<RoomHistory>,
    room_id: &str,
    status: &str,
    updated_turn: u32,
) -> (usize, bool) {
    let normalized_room_id = normalize_room_id(room_id);
    let normalized_status = normalize_room_status(status);

    for (idx, room) in rooms.iter_mut().enumerate() {
        if room.room_id == normalized_room_id {
            let mut changed = false;
            if normalized_status != "unknown" && room.status != normalized_status {
                room.status = normalized_status.clone();
                changed = true;
            }
            if updated_turn > room.updated_turn {
                room.updated_turn = updated_turn;
                changed = true;
            }
            return (idx, changed);
        }
    }

    rooms.push(RoomHistory {
        room_id: normalized_room_id.clone(),
        status: if normalized_status == "unknown" {
            "active".to_string()
        } else {
            normalized_status
        },
        turns: Vec::new(),
        updated_turn,
    });

    while rooms.len() > MAX_ROOMS_TO_KEEP {
        let remove_idx = rooms
            .iter()
            .enumerate()
            .min_by(|(_, a), (_, b)| {
                a.updated_turn
                    .cmp(&b.updated_turn)
                    .then_with(|| room_status_bucket(&b.status).cmp(&room_status_bucket(&a.status)))
                    .then_with(|| b.room_id.cmp(&a.room_id))
            })
            .map(|(idx, _)| idx)
            .unwrap_or(0);
        let _ = rooms.remove(remove_idx);
    }

    let idx = rooms
        .iter()
        .position(|room| room.room_id == normalized_room_id)
        .unwrap_or(0);
    (idx, true)
}

fn append_event(
    rooms: &mut Vec<RoomHistory>,
    room_id: &str,
    room_status: &str,
    turn: u32,
    phase: &str,
    kind: &str,
    actor: &str,
    title: &str,
    detail: &str,
) -> (bool, bool) {
    let normalized_turn = turn.max(1);
    let (room_idx, mut changed) = ensure_room_entry(rooms, room_id, room_status, normalized_turn);
    let Some(room) = rooms.get_mut(room_idx) else {
        return (false, changed);
    };

    if normalized_turn > room.updated_turn {
        room.updated_turn = normalized_turn;
        changed = true;
    }

    let (turn_idx, turn_changed) = ensure_turn_entry(&mut room.turns, normalized_turn, phase);
    changed = changed || turn_changed;
    let Some(row) = room.turns.get_mut(turn_idx) else {
        return (false, changed);
    };

    let candidate = HistoryEvent {
        kind: kind.to_string(),
        actor: actor.to_string(),
        title: title.to_string(),
        detail: detail.to_string(),
    };

    if row
        .events
        .iter()
        .rev()
        .take(48)
        .any(|existing| existing == &candidate)
    {
        return (false, changed);
    }

    row.events.push(candidate);
    if row.events.len() > MAX_EVENTS_PER_TURN {
        let overflow = row.events.len() - MAX_EVENTS_PER_TURN;
        row.events.drain(0..overflow);
    }

    (true, true)
}

fn label_progress_event(
    payload: &crate::game::events::TurnProgressPayload,
) -> (&'static str, String, String) {
    let actor = payload.actor_id.trim();
    let label = match payload.event_type.as_str() {
        "turn.started" => "턴 시작",
        "phase.changed" => "페이즈 변경",
        "narration.posted" => "내레이션",
        "turn.action.proposed" => "행동 제안",
        "turn.timeout" => "턴 타임아웃",
        "keeper.unavailable" => "Keeper 사용 불가",
        "combat.attack" => "공격",
        "combat.defense" => "방어",
        "session.outcome" => "세션 결과",
        "room.started" => "룸 시작",
        "room.ended" => "룸 종료",
        "world.event" => "월드 이벤트",
        "scene.transition" => "씬 이동",
        "quest.update" => "퀘스트 업데이트",
        "intervention.submitted" => "개입 제안됨",
        "intervention.applied" => "개입 적용",
        "actor.spawned" => "액터 추가",
        "actor.updated" => "액터 갱신",
        "actor.deleted" => "액터 삭제",
        "actor.claimed" => "액터 점유",
        "actor.released" => "액터 해제",
        _ => "진행 상태",
    };

    let mut detail = payload.reason.trim().to_string();
    if detail.is_empty() {
        detail = payload.event_type.clone();
    }
    let actor_label = if actor.is_empty() {
        "system".to_string()
    } else {
        actor.to_string()
    };
    let kind = if payload.event_type.contains("phase")
        || payload.event_type.contains("turn")
        || payload.event_type == "turn.started"
    {
        "turn"
    } else if matches!(
        payload.event_type.as_str(),
        "combat.attack" | "combat.defense" | "session.outcome"
    ) {
        "system"
    } else if matches!(payload.event_type.as_str(), "room.started" | "room.ended") {
        "system"
    } else {
        "progress"
    };
    let summary = if detail.is_empty() {
        label.to_string()
    } else {
        format!("{}: {}", label, detail)
    };
    (kind, actor_label, summary)
}

#[cfg(target_arch = "wasm32")]
fn sorted_room_refs(rooms: &[RoomHistory]) -> Vec<&RoomHistory> {
    let mut refs = rooms.iter().collect::<Vec<_>>();
    refs.sort_by(|a, b| compare_room_priority(a, b));
    refs
}

#[cfg(target_arch = "wasm32")]
fn render_room_bucket_html(title: &str, rooms: &[&RoomHistory], extra_class: &str) -> String {
    if rooms.is_empty() {
        return String::new();
    }

    let chips = rooms
        .iter()
        .map(|room| {
            let room_attr = html_escape(&sanitize_text(&room.room_id));
            let room_label = html_escape(&sanitize_text(&room.room_id));
            let status = normalize_room_status(&room.status);
            let status_label = room_status_label_ko(&status);
            let status_class = room_status_class(&status);
            let latest_turn = room
                .turns
                .iter()
                .map(|row| row.turn)
                .max()
                .or_else(|| {
                    if room.updated_turn > 0 {
                        Some(room.updated_turn)
                    } else {
                        None
                    }
                })
                .unwrap_or(1);
            format!(
                r#"<button class="history-room-chip status-{status_class}" data-room="{room_attr}" data-latest-turn="{latest_turn}" title="{room_label}" type="button"><span class="history-room-id">{room_label}</span><span class="history-room-meta">{status_label} · T{latest_turn}</span></button>"#
            )
        })
        .collect::<Vec<_>>()
        .join("");

    format!(
        r#"<section class="history-room-bucket {extra_class}"><h4 class="history-room-bucket-title">{title}</h4><div class="history-room-list">{chips}</div></section>"#,
        title = html_escape(&sanitize_text(title)),
        extra_class = html_escape(extra_class),
        chips = chips
    )
}

#[cfg(target_arch = "wasm32")]
fn render_turn_event_html(ev: &HistoryEvent) -> String {
    let actor = html_escape(&sanitize_text(&ev.actor));
    let title = html_escape(&sanitize_text(&ev.title));
    let detail = html_escape(&sanitize_text(&ev.detail));
    let kind_key = sanitize_key(&ev.kind);
    let class = history_kind_class(&kind_key);

    if actor.is_empty() {
        if detail.is_empty() {
            format!(
                r#"<li class="history-event {class}" data-kind="{kind}"><span class="history-kind">{title}</span><span class="history-detail">-</span></li>"#,
                kind = kind_key
            )
        } else {
            format!(
                r#"<li class="history-event {class}" data-kind="{kind}"><span class="history-kind">{title}</span><span class="history-detail">{detail}</span></li>"#,
                kind = kind_key
            )
        }
    } else {
        format!(
            r#"<li class="history-event {class}" data-kind="{kind}"><span class="history-kind">{title}</span><span class="history-actor">{actor}</span><span class="history-detail">{detail}</span></li>"#,
            kind = kind_key
        )
    }
}

#[cfg(target_arch = "wasm32")]
fn render_turn_panel_html(room: &RoomHistory, row: &TurnHistory) -> String {
    let room_attr = html_escape(&sanitize_text(&room.room_id));
    let phase_raw = if row.phase.trim().is_empty() {
        "unknown".to_string()
    } else {
        row.phase.trim().to_string()
    };
    let phase = html_escape(&sanitize_text(&phase_raw));
    let events = if row.events.is_empty() {
        "<li class=\"history-detail-empty\">이 턴에는 기록이 없습니다.</li>".to_string()
    } else {
        row.events
            .iter()
            .map(render_turn_event_html)
            .collect::<Vec<_>>()
            .join("")
    };

    format!(
        r#"<section class="history-detail-panel" data-room="{room_attr}" data-turn="{turn}"><header class="history-detail-header"><span class="history-detail-title">TURN {turn} · {phase}</span><span class="history-event-count">{count}</span></header><ul class="history-event-list">{events}</ul></section>"#,
        turn = row.turn,
        phase = phase,
        count = row.events.len(),
        events = events
    )
}

#[cfg(target_arch = "wasm32")]
fn render_session_history_html(rooms: &[RoomHistory], current_room_id: &str) -> String {
    if rooms.is_empty() {
        return "<div class=\"session-history-empty\">아직 세션 히스토리가 없습니다.</div>"
            .to_string();
    }

    let sorted = sorted_room_refs(rooms);
    let current_room = normalize_room_id(current_room_id);
    let active_count = sorted
        .iter()
        .filter(|room| normalize_room_status(&room.status) == "active")
        .count();
    let paused_count = sorted
        .iter()
        .filter(|room| normalize_room_status(&room.status) == "paused")
        .count();
    let ended_count = sorted
        .iter()
        .filter(|room| normalize_room_status(&room.status) == "ended")
        .count();

    let mut current_rooms = Vec::new();
    let mut active_rooms = Vec::new();
    let mut paused_rooms = Vec::new();
    let mut ended_rooms = Vec::new();
    let mut other_rooms = Vec::new();

    for room in &sorted {
        if room.room_id == current_room {
            current_rooms.push(*room);
            continue;
        }
        match room_status_bucket(&room.status) {
            0 => active_rooms.push(*room),
            1 => paused_rooms.push(*room),
            2 => ended_rooms.push(*room),
            _ => other_rooms.push(*room),
        }
    }

    let current_bucket = if current_rooms.is_empty() {
        format!(
            r#"<section class="history-room-bucket history-room-bucket-current"><h4 class="history-room-bucket-title">현재 세션</h4><p class="history-room-empty">현재 room({room})의 기록이 아직 없습니다.</p></section>"#,
            room = html_escape(&sanitize_text(&current_room))
        )
    } else {
        render_room_bucket_html("현재 세션", &current_rooms, "history-room-bucket-current")
    };

    let summary_class = if current_rooms.is_empty() {
        "history-session-summary is-missing"
    } else {
        "history-session-summary"
    };
    let summary_html = format!(
        r#"<div class="{summary_class}"><span>현재 room: <strong>{room}</strong></span><span>진행 {active} · 멈춤 {paused} · 종료 {ended}</span></div>"#,
        summary_class = summary_class,
        room = html_escape(&sanitize_text(&current_room)),
        active = active_count,
        paused = paused_count,
        ended = ended_count
    );

    let room_column = format!(
        r#"<section class="history-browser-column history-room-column"><h3 class="history-column-title">세션</h3>{summary}{current}{active}{paused}{ended}{other}</section>"#,
        summary = summary_html,
        current = current_bucket,
        active = render_room_bucket_html("이전 세션 · 진행중", &active_rooms, ""),
        paused = render_room_bucket_html("이전 세션 · 멈춤", &paused_rooms, ""),
        ended = render_room_bucket_html("이전 세션 · 종료", &ended_rooms, ""),
        other = render_room_bucket_html("이전 세션 · 기타", &other_rooms, "")
    );

    let turn_groups = sorted
        .iter()
        .map(|room| {
            let room_attr = html_escape(&sanitize_text(&room.room_id));
            let room_label = html_escape(&sanitize_text(&room.room_id));
            let chips = if room.turns.is_empty() {
                "<p class=\"history-turn-empty\">턴 기록이 없습니다.</p>".to_string()
            } else {
                room.turns
                    .iter()
                    .rev()
                    .map(|row| {
                        let phase = if row.phase.trim().is_empty() {
                            "-".to_string()
                        } else {
                            row.phase.trim().to_string()
                        };
                        format!(
                            r#"<button class="history-turn-chip" data-room="{room_attr}" data-turn="{turn}" type="button"><span class="history-turn-chip-main">T{turn}</span><span class="history-turn-chip-phase">{phase}</span><span class="history-turn-chip-count">{count}</span></button>"#,
                            turn = row.turn,
                            phase = html_escape(&sanitize_text(&phase)),
                            count = row.events.len()
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("")
            };

            format!(
                r#"<section class="history-turn-group" data-room="{room_attr}"><h4 class="history-turn-group-title">{room_label}</h4><div class="history-turn-toolbar">{chips}</div></section>"#,
                chips = chips
            )
        })
        .collect::<Vec<_>>()
        .join("");

    let turn_column = format!(
        r#"<section class="history-browser-column history-turn-column"><h3 class="history-column-title">턴</h3>{groups}</section>"#,
        groups = turn_groups
    );

    let detail_panels = sorted
        .iter()
        .map(|room| {
            if room.turns.is_empty() {
                let room_attr = html_escape(&sanitize_text(&room.room_id));
                return format!(
                    r#"<section class="history-detail-panel" data-room="{room_attr}" data-turn=""><div class="history-detail-empty">선택된 턴 기록이 없습니다.</div></section>"#
                );
            }

            room.turns
                .iter()
                .rev()
                .map(|row| render_turn_panel_html(room, row))
                .collect::<Vec<_>>()
                .join("")
        })
        .collect::<Vec<_>>()
        .join("");

    let detail_column = format!(
        r#"<section class="history-browser-column history-detail-column"><h3 class="history-column-title">상세</h3>{panels}</section>"#,
        panels = detail_panels
    );

    format!(
        r#"<div class="history-browser">{room_column}{turn_column}{detail_column}</div>"#,
        room_column = room_column,
        turn_column = turn_column,
        detail_column = detail_column
    )
}

#[cfg(target_arch = "wasm32")]
fn normalize_focus_room(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

#[cfg(target_arch = "wasm32")]
fn read_focus_room(document: &web_sys::Document) -> Option<String> {
    document
        .get_element_by_id("dashboard")
        .and_then(|el| el.get_attribute("data-focus-room"))
        .and_then(|raw| normalize_focus_room(&raw))
}

#[cfg(target_arch = "wasm32")]
fn write_focus_room(document: &web_sys::Document, room: Option<&str>) {
    let Some(dashboard) = document.get_element_by_id("dashboard") else {
        return;
    };
    if let Some(room) = room.and_then(normalize_focus_room) {
        let _ = dashboard.set_attribute("data-focus-room", &room);
    } else {
        let _ = dashboard.remove_attribute("data-focus-room");
    }
}

#[cfg(target_arch = "wasm32")]
fn read_focus_turn(document: &web_sys::Document) -> Option<u32> {
    document
        .get_element_by_id("dashboard")
        .and_then(|el| el.get_attribute("data-focus-turn"))
        .and_then(|raw| raw.trim().parse::<u32>().ok())
        .filter(|turn| *turn > 0)
}

#[cfg(target_arch = "wasm32")]
fn write_focus_turn(document: &web_sys::Document, turn: Option<u32>) {
    let Some(dashboard) = document.get_element_by_id("dashboard") else {
        return;
    };
    if let Some(turn) = turn.filter(|value| *value > 0) {
        let _ = dashboard.set_attribute("data-focus-turn", &turn.to_string());
    } else {
        let _ = dashboard.remove_attribute("data-focus-turn");
    }
}

#[cfg(target_arch = "wasm32")]
fn read_focus_from_hash() -> (Option<String>, Option<u32>) {
    let Some(window) = web_sys::window() else {
        return (None, None);
    };
    let Ok(raw_hash) = window.location().hash() else {
        return (None, None);
    };
    let fragment = raw_hash.trim().trim_start_matches('#');
    let Some((_, params)) = fragment
        .split_once('?')
        .or_else(|| fragment.split_once('&'))
    else {
        return (None, None);
    };

    let mut room = None;
    let mut turn = None;
    for pair in params.split('&') {
        if pair.is_empty() {
            continue;
        }
        let mut parts = pair.splitn(2, '=');
        let key = parts.next().unwrap_or_default().trim().to_ascii_lowercase();
        let value = parts.next().unwrap_or_default().trim();
        match key.as_str() {
            "room" if room.is_none() => {
                room = normalize_focus_room(value);
            }
            "turn" if turn.is_none() => {
                if let Ok(parsed) = value.parse::<u32>() {
                    if parsed > 0 {
                        turn = Some(parsed);
                    }
                }
            }
            _ => {}
        }
    }
    (room, turn)
}

#[cfg(target_arch = "wasm32")]
fn write_focus_hash(room: Option<&str>, turn: Option<u32>) {
    let Some(window) = web_sys::window() else {
        return;
    };
    let raw_hash = window.location().hash().unwrap_or_default();
    let fragment = raw_hash.trim().trim_start_matches('#');
    let base = fragment
        .split(|ch| ch == '?' || ch == '&')
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("trpg");

    let mut params = Vec::new();
    if let Some(room) = room.and_then(normalize_focus_room) {
        params.push(format!("room={}", room));
    }
    if let Some(turn) = turn.filter(|value| *value > 0) {
        params.push(format!("turn={}", turn));
    }

    let next_fragment = if params.is_empty() {
        base.to_string()
    } else {
        format!("{}&{}", base, params.join("&"))
    };
    if fragment == next_fragment {
        return;
    }

    if let Ok(history) = window.history() {
        let path = window.location().pathname().unwrap_or_default();
        let search = window.location().search().unwrap_or_default();
        let url = format!("{}{}#{}", path, search, next_fragment);
        let _ = history.replace_state_with_url(&wasm_bindgen::JsValue::NULL, "", Some(&url));
    } else {
        let _ = window.location().set_hash(&next_fragment);
    }
}

#[cfg(target_arch = "wasm32")]
fn sync_focus_state_to_hash(document: &web_sys::Document) {
    let room = read_focus_room(document);
    let turn = read_focus_turn(document);
    write_focus_hash(room.as_deref(), turn);
}

#[cfg(target_arch = "wasm32")]
pub(super) fn sync_history_focus_from_dashboard(document: &web_sys::Document) {
    let room = read_focus_room(document);
    let turn = read_focus_turn(document);
    apply_history_focus(document, room.as_deref(), turn);
    sync_focus_state_to_hash(document);
}

#[cfg(not(target_arch = "wasm32"))]
pub(super) fn sync_history_focus_from_dashboard(_document: &web_sys::Document) {}

#[cfg(target_arch = "wasm32")]
fn resolve_focus_room(rooms: &[RoomHistory], preferred: Option<&str>) -> Option<String> {
    if rooms.is_empty() {
        return None;
    }

    if let Some(room_id) = preferred.and_then(normalize_focus_room) {
        if rooms.iter().any(|room| room.room_id == room_id) {
            return Some(room_id);
        }
    }

    let mut refs = rooms.iter().collect::<Vec<_>>();
    refs.sort_by(|a, b| compare_room_priority(a, b));
    refs.first().map(|room| room.room_id.clone())
}

#[cfg(target_arch = "wasm32")]
fn resolve_focus_turn(
    rooms: &[RoomHistory],
    room_id: Option<&str>,
    preferred: Option<u32>,
) -> Option<u32> {
    let target_room = room_id.and_then(|room| rooms.iter().find(|entry| entry.room_id == room))?;

    if let Some(turn) = preferred.filter(|value| *value > 0) {
        if target_room.turns.iter().any(|row| row.turn == turn) {
            return Some(turn);
        }
    }

    target_room
        .turns
        .iter()
        .map(|row| row.turn)
        .max()
        .or_else(|| {
            if target_room.updated_turn > 0 {
                Some(target_room.updated_turn)
            } else {
                None
            }
        })
}

#[cfg(target_arch = "wasm32")]
fn apply_history_focus(document: &web_sys::Document, room: Option<&str>, turn: Option<u32>) {
    let room_key = room.and_then(normalize_focus_room);
    let turn_key = turn
        .filter(|value| *value > 0)
        .map(|value| value.to_string());

    for selector in ["#narrative-log .narrative-entry", "#dice-log .dice-entry"] {
        let Ok(nodes) = document.query_selector_all(selector) else {
            continue;
        };
        for idx in 0..nodes.length() {
            let Some(node) = nodes.item(idx) else {
                continue;
            };
            let Some(el) = node.dyn_ref::<web_sys::Element>() else {
                continue;
            };
            let turn_ok = match turn_key.as_deref() {
                Some(target) => el
                    .get_attribute("data-turn")
                    .map(|value| value == target)
                    .unwrap_or(false),
                None => true,
            };
            if turn_ok {
                let _ = el.class_list().remove_1("turn-dim");
                let _ = el.class_list().add_1("turn-match");
            } else {
                let _ = el.class_list().remove_1("turn-match");
                let _ = el.class_list().add_1("turn-dim");
            }
        }
    }

    if let Ok(chips) = document.query_selector_all("#session-history .history-room-chip") {
        for idx in 0..chips.length() {
            let Some(node) = chips.item(idx) else {
                continue;
            };
            let Some(el) = node.dyn_ref::<web_sys::Element>() else {
                continue;
            };
            let chip_room = el.get_attribute("data-room").unwrap_or_default();
            let active = room_key
                .as_deref()
                .map(|target| chip_room == target)
                .unwrap_or(false);
            if active {
                let _ = el.class_list().add_1("is-active");
            } else {
                let _ = el.class_list().remove_1("is-active");
            }
        }
    }

    if let Ok(groups) = document.query_selector_all("#session-history .history-turn-group") {
        for idx in 0..groups.length() {
            let Some(node) = groups.item(idx) else {
                continue;
            };
            let Some(el) = node.dyn_ref::<web_sys::Element>() else {
                continue;
            };
            let group_room = el.get_attribute("data-room").unwrap_or_default();
            let visible = room_key
                .as_deref()
                .map(|target| group_room == target)
                .unwrap_or(false);
            if visible {
                let _ = el.class_list().remove_1("history-room-hidden");
            } else {
                let _ = el.class_list().add_1("history-room-hidden");
            }
        }
    }

    if let Ok(chips) = document.query_selector_all("#session-history .history-turn-chip") {
        for idx in 0..chips.length() {
            let Some(node) = chips.item(idx) else {
                continue;
            };
            let Some(el) = node.dyn_ref::<web_sys::Element>() else {
                continue;
            };
            let chip_room = el.get_attribute("data-room").unwrap_or_default();
            let chip_turn = el.get_attribute("data-turn").unwrap_or_default();
            let room_ok = room_key
                .as_deref()
                .map(|target| chip_room == target)
                .unwrap_or(false);
            let turn_ok = turn_key
                .as_deref()
                .map(|target| chip_turn == target)
                .unwrap_or(false);
            if room_ok && turn_ok {
                let _ = el.class_list().add_1("is-active");
            } else {
                let _ = el.class_list().remove_1("is-active");
            }
        }
    }

    if let Ok(panels) = document.query_selector_all("#session-history .history-detail-panel") {
        for idx in 0..panels.length() {
            let Some(node) = panels.item(idx) else {
                continue;
            };
            let Some(el) = node.dyn_ref::<web_sys::Element>() else {
                continue;
            };
            let panel_room = el.get_attribute("data-room").unwrap_or_default();
            let panel_turn = el.get_attribute("data-turn").unwrap_or_default();
            let room_ok = room_key
                .as_deref()
                .map(|target| panel_room == target)
                .unwrap_or(false);
            let turn_ok = match turn_key.as_deref() {
                Some(target) => panel_turn == target,
                None => panel_turn.trim().is_empty(),
            };
            if room_ok && turn_ok {
                let _ = el.class_list().remove_1("history-panel-hidden");
            } else {
                let _ = el.class_list().add_1("history-panel-hidden");
            }
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn bind_history_focus_controls(document: &web_sys::Document) {
    if let Ok(chips) = document.query_selector_all("#session-history .history-room-chip") {
        for idx in 0..chips.length() {
            let Some(node) = chips.item(idx) else {
                continue;
            };
            let Some(el) = node.dyn_ref::<web_sys::Element>() else {
                continue;
            };
            if el.get_attribute("data-bound").as_deref() == Some("1") {
                continue;
            }
            let _ = el.set_attribute("data-bound", "1");
            let room_raw = el.get_attribute("data-room").unwrap_or_default();
            let latest_turn_raw = el.get_attribute("data-latest-turn").unwrap_or_default();
            let cb = Closure::wrap(Box::new(move || {
                let Some(document) = web_sys::window().and_then(|w| w.document()) else {
                    return;
                };
                let room = normalize_focus_room(&room_raw);
                let turn = latest_turn_raw
                    .trim()
                    .parse::<u32>()
                    .ok()
                    .filter(|value| *value > 0);
                write_focus_room(&document, room.as_deref());
                write_focus_turn(&document, turn);
                apply_history_focus(&document, room.as_deref(), turn);
                sync_focus_state_to_hash(&document);
            }) as Box<dyn FnMut()>);
            let _ = el.dyn_ref::<web_sys::EventTarget>().map(|target| {
                target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
            });
            cb.forget();
        }
    }

    if let Ok(chips) = document.query_selector_all("#session-history .history-turn-chip") {
        for idx in 0..chips.length() {
            let Some(node) = chips.item(idx) else {
                continue;
            };
            let Some(el) = node.dyn_ref::<web_sys::Element>() else {
                continue;
            };
            if el.get_attribute("data-bound").as_deref() == Some("1") {
                continue;
            }
            let _ = el.set_attribute("data-bound", "1");
            let room_raw = el.get_attribute("data-room").unwrap_or_default();
            let turn_raw = el.get_attribute("data-turn").unwrap_or_default();
            let cb = Closure::wrap(Box::new(move || {
                let Some(document) = web_sys::window().and_then(|w| w.document()) else {
                    return;
                };
                let room = normalize_focus_room(&room_raw);
                let turn = turn_raw
                    .trim()
                    .parse::<u32>()
                    .ok()
                    .filter(|value| *value > 0);
                write_focus_room(&document, room.as_deref());
                write_focus_turn(&document, turn);
                apply_history_focus(&document, room.as_deref(), turn);
                sync_focus_state_to_hash(&document);
            }) as Box<dyn FnMut()>);
            let _ = el.dyn_ref::<web_sys::EventTarget>().map(|target| {
                target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
            });
            cb.forget();
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn bump_dedup_history(document: &web_sys::Document, sample: &str) {
    let Some(dashboard) = document.get_element_by_id("dashboard") else {
        return;
    };
    let next = dashboard
        .get_attribute("data-dedup-history")
        .and_then(|raw| raw.parse::<u64>().ok())
        .unwrap_or(0)
        .saturating_add(1);
    let _ = dashboard.set_attribute("data-dedup-history", &next.to_string());

    let mut lines = dashboard
        .get_attribute("data-dedup-samples-history")
        .unwrap_or_default()
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    let trimmed = sample.trim();
    if !trimmed.is_empty() {
        lines.push(trimmed.chars().take(160).collect());
    }
    if lines.len() > 24 {
        let drain = lines.len() - 24;
        lines.drain(0..drain);
    }
    let _ = dashboard.set_attribute("data-dedup-samples-history", &lines.join("\n"));
}

/// Render a per-room, per-turn timeline from TRPG stream events.
#[allow(unused_variables, unused_mut)]
pub fn update_session_history_dom(
    room_state: Res<RoomState>,
    progress: Res<TurnProgressState>,
    mut narratives: MessageReader<NarrativeReceived>,
    mut dice_events: MessageReader<DiceRolled>,
    mut turn_events: MessageReader<TurnAdvanced>,
    mut progress_events: MessageReader<TurnProgressUpdated>,
    mut cache: ResMut<SessionHistoryCache>,
) {
    #[cfg(not(target_arch = "wasm32"))]
    {
        for _ in turn_events.read() {}
        for _ in narratives.read() {}
        for _ in dice_events.read() {}
        for _ in progress_events.read() {}
        return;
    }

    #[cfg(target_arch = "wasm32")]
    {
        let Some(document) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let Some(history) = document.get_element_by_id("session-history") else {
            return;
        };

        let mut changed = false;
        let base_room_id = normalize_room_id(&room_state.id);
        let mut base_room_status = {
            let from_progress = normalize_room_status(&progress.room_status);
            if from_progress == "unknown" {
                normalize_room_status(&room_state.status)
            } else {
                from_progress
            }
        };
        if base_room_status == "unknown" {
            base_room_status = "active".to_string();
        }

        let mut current_turn = if progress.turn > 0 {
            progress.turn
        } else {
            room_state.turn.max(1)
        };
        let mut current_phase = if !progress.phase.is_empty() {
            progress.phase.clone()
        } else {
            room_state.phase.as_str().to_string()
        };

        let (room_idx, room_changed) = ensure_room_entry(
            &mut cache.rooms,
            &base_room_id,
            &base_room_status,
            current_turn,
        );
        changed = changed || room_changed;
        if let Some(room) = cache.rooms.get_mut(room_idx) {
            let (_, turn_changed) =
                ensure_turn_entry(&mut room.turns, current_turn, &current_phase);
            changed = changed || turn_changed;
        }

        for TurnAdvanced(event) in turn_events.read() {
            if event.turn > 0 {
                current_turn = event.turn;
            }
            if !event.phase.is_empty() {
                current_phase = event.phase.clone();
            }

            let event_room_id = if event.room_id.trim().is_empty() {
                base_room_id.clone()
            } else {
                normalize_room_id(&event.room_id)
            };

            let (appended, updated) = append_event(
                &mut cache.rooms,
                &event_room_id,
                &base_room_status,
                current_turn,
                &current_phase,
                "turn",
                "",
                "턴 진행",
                &format!(
                    "Turn {} ({})",
                    current_turn,
                    if current_phase.is_empty() {
                        "-"
                    } else {
                        &current_phase
                    }
                ),
            );
            if !appended {
                bump_dedup_history(
                    &document,
                    &format!(
                        "{} | t{} | turn | {}",
                        event_room_id, current_turn, current_phase
                    ),
                );
            }
            changed = changed || updated;
        }

        for NarrativeReceived(event) in narratives.read() {
            let event_turn = if event.turn > 0 {
                event.turn
            } else {
                current_turn
            };
            let event_phase = if !event.phase.trim().is_empty() {
                event.phase.clone()
            } else {
                current_phase.clone()
            };
            let event_room_id = if event.room_id.trim().is_empty() {
                base_room_id.clone()
            } else {
                normalize_room_id(&event.room_id)
            };

            let (appended, updated) = append_event(
                &mut cache.rooms,
                &event_room_id,
                &base_room_status,
                event_turn,
                &event_phase,
                "narrative",
                event.speaker.as_deref().unwrap_or(""),
                "내러티브",
                &event.text,
            );
            if !appended {
                bump_dedup_history(
                    &document,
                    &format!(
                        "{} | t{} | narrative | {}",
                        event_room_id,
                        event_turn,
                        event.text.trim()
                    ),
                );
            }
            changed = changed || updated;
            current_turn = event_turn.max(1);
            current_phase = event_phase;
        }

        for DiceRolled(payload) in dice_events.read() {
            let event_turn = if payload.turn > 0 {
                payload.turn
            } else {
                current_turn
            };
            let event_room_id = if payload.room_id.trim().is_empty() {
                base_room_id.clone()
            } else {
                normalize_room_id(&payload.room_id)
            };

            let (appended, updated) = append_event(
                &mut cache.rooms,
                &event_room_id,
                &base_room_status,
                event_turn,
                &current_phase,
                "dice",
                &payload.character,
                "주사위",
                &format!(
                    "{} - {} (d20 {} + {} = {}, DC {})",
                    payload.character,
                    payload.action,
                    payload.d20,
                    payload.bonus,
                    payload.total,
                    payload.dc
                ),
            );
            if !appended {
                bump_dedup_history(
                    &document,
                    &format!(
                        "{} | t{} | dice | {}:{}",
                        event_room_id, event_turn, payload.character, payload.action
                    ),
                );
            }
            changed = changed || updated;
            current_turn = event_turn.max(1);
        }

        for TurnProgressUpdated(event) in progress_events.read() {
            let event_turn = if event.turn > 0 {
                event.turn
            } else {
                current_turn
            };
            let event_phase = if !event.phase.is_empty() {
                event.phase.clone()
            } else {
                current_phase.clone()
            };
            let event_room_id = if event.room_id.trim().is_empty() {
                base_room_id.clone()
            } else {
                normalize_room_id(&event.room_id)
            };
            let event_status = {
                let normalized = normalize_room_status(&event.room_status);
                if normalized == "unknown" {
                    base_room_status.clone()
                } else {
                    normalized
                }
            };

            let (kind, actor, summary) = label_progress_event(event);
            let (appended, updated) = append_event(
                &mut cache.rooms,
                &event_room_id,
                &event_status,
                event_turn,
                &event_phase,
                kind,
                &actor,
                if summary.is_empty() {
                    "turn progress"
                } else {
                    &summary
                },
                &event.event_type,
            );
            if !appended {
                bump_dedup_history(
                    &document,
                    &format!(
                        "{} | t{} | progress | {}",
                        event_room_id, event_turn, event.event_type
                    ),
                );
            }
            changed = changed || updated;
            current_turn = event_turn.max(1);
            current_phase = event_phase;
            base_room_status = event_status;
        }

        let (room_idx, room_changed) = ensure_room_entry(
            &mut cache.rooms,
            &base_room_id,
            &base_room_status,
            current_turn,
        );
        changed = changed || room_changed;
        if let Some(room) = cache.rooms.get_mut(room_idx) {
            let (_, turn_changed) =
                ensure_turn_entry(&mut room.turns, current_turn, &current_phase);
            changed = changed || turn_changed;
        }

        if !changed {
            return;
        }

        let current_room_id = crate::config::current_room_id();
        history.set_inner_html(&render_session_history_html(&cache.rooms, &current_room_id));
        bind_history_focus_controls(&document);

        let (hash_room, hash_turn) = read_focus_from_hash();
        let preferred_room = read_focus_room(&document)
            .or(hash_room)
            .or_else(|| Some(base_room_id.clone()));
        let preferred_turn = read_focus_turn(&document)
            .or(hash_turn)
            .or(Some(current_turn.max(1)));

        let focus_room = resolve_focus_room(&cache.rooms, preferred_room.as_deref());
        let focus_turn = resolve_focus_turn(&cache.rooms, focus_room.as_deref(), preferred_turn);

        write_focus_room(&document, focus_room.as_deref());
        write_focus_turn(&document, focus_turn);
        apply_history_focus(&document, focus_room.as_deref(), focus_turn);
        sync_focus_state_to_hash(&document);
    }
}
