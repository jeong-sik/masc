//! TRPG session timeline.
//!
//! Captures narrative, dice, and turn-progress events into per-workspace,
//! per-turn history and renders them as a compact browser.

#![allow(dead_code)] // Many helpers used only in wasm32 cfg blocks.

use bevy::ecs::system::SystemParam;
use bevy::prelude::*;
use std::cmp::Ordering;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::closure::Closure;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;

use crate::game::events::{
    DiceRolled, NarrativeReceived, SessionStarted, TurnAdvanced, TurnProgressUpdated,
};
use crate::game::state::{WorkspaceState, TurnProgressState};

const MAX_WORKSPACES_TO_KEEP: usize = 24;
const MAX_TURNS_TO_KEEP: usize = 24;
const MAX_EVENTS_PER_TURN: usize = 80;
const UNKNOWN_WORKSPACE_ID: &str = "workspace-unknown";

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
struct WorkspaceHistory {
    workspace_id: String,
    status: String,
    turns: Vec<TurnHistory>,
    updated_turn: u32,
    session_id: String,
}

#[derive(Resource, Default)]
pub struct SessionHistoryCache {
    workspaces: Vec<WorkspaceHistory>,
}

#[derive(SystemParam)]
pub struct SessionHistoryReaders<'w, 's> {
    narratives: MessageReader<'w, 's, NarrativeReceived>,
    dice_events: MessageReader<'w, 's, DiceRolled>,
    turn_events: MessageReader<'w, 's, TurnAdvanced>,
    progress_events: MessageReader<'w, 's, TurnProgressUpdated>,
    session_started: MessageReader<'w, 's, SessionStarted>,
}

#[cfg(target_arch = "wasm32")]
use super::escape::{html_escape, sanitize_text};

fn sanitize_key(raw: &str) -> String {
    raw.trim().to_ascii_lowercase()
}

fn normalize_workspace_id(raw: &str) -> String {
    let normalized = crate::config::sanitize_workspace_id(raw)
        .unwrap_or_else(|| raw.trim().to_string())
        .trim()
        .to_ascii_lowercase();
    if normalized.is_empty() {
        UNKNOWN_WORKSPACE_ID.to_string()
    } else {
        normalized
    }
}

fn normalize_workspace_status(raw: &str) -> String {
    let key = sanitize_key(raw);
    match key.as_str() {
        "active" | "running" | "started" | "in_progress" | "in-progress" | "playing" | "open" => {
            "active"
        }
        "paused" | "pause" | "stopped" | "on_hold" | "on-hold" => "paused",
        "idle" | "created" | "ready" => "unknown",
        "ended" | "finished" | "completed" | "closed" | "done" | "archived" | "terminated" => {
            "ended"
        }
        _ => "unknown",
    }
    .to_string()
}

fn workspace_status_bucket(status: &str) -> u8 {
    match normalize_workspace_status(status).as_str() {
        "active" => 0,
        "paused" => 1,
        "ended" => 2,
        _ => 3,
    }
}

fn workspace_status_label_ko(status: &str) -> &'static str {
    match normalize_workspace_status(status).as_str() {
        "active" => "진행중",
        "paused" => "멈춤",
        "ended" => "종료",
        _ => "기타",
    }
}

fn workspace_status_class(status: &str) -> &'static str {
    match normalize_workspace_status(status).as_str() {
        "active" => "active",
        "paused" => "paused",
        "ended" => "ended",
        _ => "unknown",
    }
}

fn compare_workspace_priority(a: &WorkspaceHistory, b: &WorkspaceHistory) -> Ordering {
    workspace_status_bucket(&a.status)
        .cmp(&workspace_status_bucket(&b.status))
        .then_with(|| b.updated_turn.cmp(&a.updated_turn))
        .then_with(|| a.workspace_id.cmp(&b.workspace_id))
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

fn ensure_workspace_entry(
    workspaces: &mut Vec<WorkspaceHistory>,
    workspace_id: &str,
    status: &str,
    updated_turn: u32,
) -> (usize, bool) {
    let normalized_workspace_id = normalize_workspace_id(workspace_id);
    let normalized_status = normalize_workspace_status(status);

    for (idx, workspace) in workspaces.iter_mut().enumerate() {
        if workspace.workspace_id == normalized_workspace_id {
            let mut changed = false;
            if normalized_status != "unknown" && workspace.status != normalized_status {
                workspace.status = normalized_status.clone();
                changed = true;
            }
            if updated_turn > workspace.updated_turn {
                workspace.updated_turn = updated_turn;
                changed = true;
            }
            return (idx, changed);
        }
    }

    workspaces.push(WorkspaceHistory {
        workspace_id: normalized_workspace_id.clone(),
        status: if normalized_status == "unknown" {
            "active".to_string()
        } else {
            normalized_status
        },
        turns: Vec::new(),
        updated_turn,
        session_id: String::new(),
    });

    while workspaces.len() > MAX_WORKSPACES_TO_KEEP {
        let remove_idx = workspaces
            .iter()
            .enumerate()
            .min_by(|(_, a), (_, b)| {
                a.updated_turn
                    .cmp(&b.updated_turn)
                    .then_with(|| workspace_status_bucket(&b.status).cmp(&workspace_status_bucket(&a.status)))
                    .then_with(|| b.workspace_id.cmp(&a.workspace_id))
            })
            .map(|(idx, _)| idx)
            .unwrap_or(0);
        let _ = workspaces.remove(remove_idx);
    }

    let idx = workspaces
        .iter()
        .position(|workspace| workspace.workspace_id == normalized_workspace_id)
        .unwrap_or(0);
    (idx, true)
}

struct EventAppendInput<'a> {
    workspace_id: &'a str,
    workspace_status: &'a str,
    turn: u32,
    phase: &'a str,
    kind: &'a str,
    actor: &'a str,
    title: &'a str,
    detail: &'a str,
}

fn append_event(workspaces: &mut Vec<WorkspaceHistory>, input: EventAppendInput<'_>) -> (bool, bool) {
    let normalized_turn = input.turn.max(1);
    let (workspace_idx, mut changed) =
        ensure_workspace_entry(workspaces, input.workspace_id, input.workspace_status, normalized_turn);
    let Some(workspace) = workspaces.get_mut(workspace_idx) else {
        return (false, changed);
    };

    if normalized_turn > workspace.updated_turn {
        workspace.updated_turn = normalized_turn;
        changed = true;
    }

    let (turn_idx, turn_changed) = ensure_turn_entry(&mut workspace.turns, normalized_turn, input.phase);
    changed = changed || turn_changed;
    let Some(row) = workspace.turns.get_mut(turn_idx) else {
        return (false, changed);
    };

    let candidate = HistoryEvent {
        kind: input.kind.to_string(),
        actor: input.actor.to_string(),
        title: input.title.to_string(),
        detail: input.detail.to_string(),
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
        "workspace.started" => "룸 시작",
        "workspace.ended" => "룸 종료",
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
        "combat.attack" | "combat.defense" | "session.outcome" | "workspace.started" | "workspace.ended"
    ) {
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
fn sorted_workspace_refs(workspaces: &[WorkspaceHistory]) -> Vec<&WorkspaceHistory> {
    let mut refs = workspaces.iter().collect::<Vec<_>>();
    let has_real_workspace = refs.iter().any(|workspace| workspace.workspace_id != UNKNOWN_WORKSPACE_ID);
    if has_real_workspace {
        refs.retain(|workspace| workspace.workspace_id != UNKNOWN_WORKSPACE_ID);
    }
    refs.sort_by(|a, b| compare_workspace_priority(a, b));
    refs
}

#[cfg(target_arch = "wasm32")]
fn render_workspace_bucket_html(title: &str, workspaces: &[&WorkspaceHistory], extra_class: &str) -> String {
    if workspaces.is_empty() {
        return String::new();
    }

    let chips = workspaces
        .iter()
        .map(|workspace| {
            let workspace_attr = html_escape(&sanitize_text(&workspace.workspace_id));
            let workspace_label = html_escape(&sanitize_text(&workspace.workspace_id));
            let status = normalize_workspace_status(&workspace.status);
            let status_label = workspace_status_label_ko(&status);
            let status_class = workspace_status_class(&status);
            let latest_turn = workspace
                .turns
                .iter()
                .map(|row| row.turn)
                .max()
                .or_else(|| {
                    if workspace.updated_turn > 0 {
                        Some(workspace.updated_turn)
                    } else {
                        None
                    }
                })
                .unwrap_or(1);
            format!(
                r#"<button class="history-workspace-chip status-{status_class}" data-workspace="{workspace_attr}" data-latest-turn="{latest_turn}" title="{workspace_label}" type="button"><span class="history-workspace-id">{workspace_label}</span><span class="history-workspace-meta">{status_label} · T{latest_turn}</span></button>"#
            )
        })
        .collect::<Vec<_>>()
        .join("");

    format!(
        r#"<section class="history-workspace-bucket {extra_class}"><h4 class="history-workspace-bucket-title">{title}</h4><div class="history-workspace-list">{chips}</div></section>"#,
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
fn render_turn_panel_html(workspace: &WorkspaceHistory, row: &TurnHistory) -> String {
    let workspace_attr = html_escape(&sanitize_text(&workspace.workspace_id));
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
        r#"<section class="history-detail-panel" data-workspace="{workspace_attr}" data-turn="{turn}"><header class="history-detail-header"><span class="history-detail-title">TURN {turn} · {phase}</span><span class="history-event-count">{count}</span></header><ul class="history-event-list">{events}</ul></section>"#,
        turn = row.turn,
        phase = phase,
        count = row.events.len(),
        events = events
    )
}

#[cfg(target_arch = "wasm32")]
fn render_session_history_html(workspaces: &[WorkspaceHistory], current_workspace_id: &str) -> String {
    if workspaces.is_empty() {
        return "<div class=\"session-history-empty\">아직 세션 히스토리가 없습니다.</div>"
            .to_string();
    }

    let sorted = sorted_workspace_refs(workspaces);
    let current_workspace = normalize_workspace_id(current_workspace_id);
    let active_count = sorted
        .iter()
        .filter(|workspace| normalize_workspace_status(&workspace.status) == "active")
        .count();
    let paused_count = sorted
        .iter()
        .filter(|workspace| normalize_workspace_status(&workspace.status) == "paused")
        .count();
    let ended_count = sorted
        .iter()
        .filter(|workspace| normalize_workspace_status(&workspace.status) == "ended")
        .count();

    let mut current_workspaces = Vec::new();
    let mut active_workspaces = Vec::new();
    let mut paused_workspaces = Vec::new();
    let mut ended_workspaces = Vec::new();
    let mut other_workspaces = Vec::new();

    for workspace in &sorted {
        if workspace.workspace_id == current_workspace {
            current_workspaces.push(*workspace);
            continue;
        }
        match workspace_status_bucket(&workspace.status) {
            0 => active_workspaces.push(*workspace),
            1 => paused_workspaces.push(*workspace),
            2 => ended_workspaces.push(*workspace),
            _ => other_workspaces.push(*workspace),
        }
    }

    let has_previous_sessions = !active_workspaces.is_empty()
        || !paused_workspaces.is_empty()
        || !ended_workspaces.is_empty()
        || !other_workspaces.is_empty();

    let current_bucket = if current_workspaces.is_empty() {
        format!(
            r#"<section class="history-workspace-bucket history-workspace-bucket-current"><h4 class="history-workspace-bucket-title">현재 게임 (실시간)</h4><p class="history-workspace-empty">현재 game workspace({workspace})의 기록이 없습니다. 새 게임을 시작하거나 라운드를 실행하세요.</p></section>"#,
            workspace = html_escape(&sanitize_text(&current_workspace))
        )
    } else {
        render_workspace_bucket_html(
            "현재 게임 (실시간)",
            &current_workspaces,
            "history-workspace-bucket-current",
        )
    };

    let summary_class = if current_workspaces.is_empty() {
        "history-session-summary is-missing"
    } else {
        "history-session-summary"
    };
    let summary_html = if has_previous_sessions {
        format!(
            r#"<div class="{summary_class}"><span>현재 게임 workspace: <strong>{workspace}</strong></span><span>이전 세션 진행 {active} · 멈춤 {paused} · 종료 {ended}</span></div>"#,
            summary_class = summary_class,
            workspace = html_escape(&sanitize_text(&current_workspace)),
            active = active_count,
            paused = paused_count,
            ended = ended_count
        )
    } else {
        format!(
            r#"<div class="{summary_class}"><span>현재 게임 workspace: <strong>{workspace}</strong></span><span>이전 세션이 없습니다.</span></div>"#,
            summary_class = summary_class,
            workspace = html_escape(&sanitize_text(&current_workspace))
        )
    };

    let workspace_column = if has_previous_sessions {
        format!(
            r#"<section class="history-browser-column history-workspace-column"><h3 class="history-column-title">현재 게임 / 이전 세션</h3>{summary}{current}{active}{paused}{ended}{other}</section>"#,
            summary = summary_html,
            current = current_bucket,
            active = render_workspace_bucket_html("이전 세션 · 진행 중", &active_workspaces, ""),
            paused = render_workspace_bucket_html("이전 세션 · 멈춤", &paused_workspaces, ""),
            ended = render_workspace_bucket_html("이전 세션 · 종료", &ended_workspaces, ""),
            other = render_workspace_bucket_html("이전 세션 · 기타", &other_workspaces, "")
        )
    } else {
        format!(
            r#"<section class="history-browser-column history-workspace-column"><h3 class="history-column-title">현재 게임</h3>{summary}{current}</section>"#,
            summary = summary_html,
            current = current_bucket
        )
    };

    let turn_groups = sorted
        .iter()
        .map(|workspace| {
            let workspace_attr = html_escape(&sanitize_text(&workspace.workspace_id));
            let workspace_label = html_escape(&sanitize_text(&workspace.workspace_id));
            let chips = if workspace.turns.is_empty() {
                "<p class=\"history-turn-empty\">턴 기록이 없습니다.</p>".to_string()
            } else {
                workspace.turns
                    .iter()
                    .rev()
                    .map(|row| {
                        let phase = if row.phase.trim().is_empty() {
                            "-".to_string()
                        } else {
                            row.phase.trim().to_string()
                        };
                        format!(
                            r#"<button class="history-turn-chip" data-workspace="{workspace_attr}" data-turn="{turn}" type="button"><span class="history-turn-chip-main">T{turn}</span><span class="history-turn-chip-phase">{phase}</span><span class="history-turn-chip-count">{count}</span></button>"#,
                            turn = row.turn,
                            phase = html_escape(&sanitize_text(&phase)),
                            count = row.events.len()
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("")
            };

            format!(
                r#"<section class="history-turn-group" data-workspace="{workspace_attr}"><h4 class="history-turn-group-title">{workspace_label}</h4><div class="history-turn-toolbar">{chips}</div></section>"#,
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
        .map(|workspace| {
            if workspace.turns.is_empty() {
                let workspace_attr = html_escape(&sanitize_text(&workspace.workspace_id));
                return format!(
                    r#"<section class="history-detail-panel" data-workspace="{workspace_attr}" data-turn=""><div class="history-detail-empty">선택된 턴 기록이 없습니다.</div></section>"#
                );
            }

            workspace.turns
                .iter()
                .rev()
                .map(|row| render_turn_panel_html(workspace, row))
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
        r#"<div class="history-browser">{workspace_column}{turn_column}{detail_column}</div>"#,
        workspace_column = workspace_column,
        turn_column = turn_column,
        detail_column = detail_column
    )
}

#[cfg(target_arch = "wasm32")]
fn normalize_focus_workspace(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.eq_ignore_ascii_case(UNKNOWN_WORKSPACE_ID) {
        None
    } else {
        Some(trimmed.to_string())
    }
}

#[cfg(target_arch = "wasm32")]
fn read_focus_workspace(document: &web_sys::Document) -> Option<String> {
    document
        .get_element_by_id("dashboard")
        .and_then(|el| el.get_attribute("data-focus-workspace"))
        .and_then(|raw| normalize_focus_workspace(&raw))
}

#[cfg(target_arch = "wasm32")]
fn write_focus_workspace(document: &web_sys::Document, workspace: Option<&str>) {
    let Some(dashboard) = document.get_element_by_id("dashboard") else {
        return;
    };
    if let Some(workspace) = workspace.and_then(normalize_focus_workspace) {
        let _ = dashboard.set_attribute("data-focus-workspace", &workspace);
    } else {
        let _ = dashboard.remove_attribute("data-focus-workspace");
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

    let mut workspace = None;
    let mut turn = None;
    for pair in params.split('&') {
        if pair.is_empty() {
            continue;
        }
        let mut parts = pair.splitn(2, '=');
        let key = parts.next().unwrap_or_default().trim().to_ascii_lowercase();
        let value = parts.next().unwrap_or_default().trim();
        match key.as_str() {
            "workspace" if workspace.is_none() => {
                workspace = normalize_focus_workspace(value);
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
    (workspace, turn)
}

#[cfg(target_arch = "wasm32")]
fn write_focus_hash(workspace: Option<&str>, turn: Option<u32>) {
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
    if let Some(workspace) = workspace.and_then(normalize_focus_workspace) {
        params.push(format!("workspace={}", workspace));
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
    let _ = document;
}

#[cfg(target_arch = "wasm32")]
pub(super) fn sync_history_focus_from_dashboard(document: &web_sys::Document) {
    let workspace = read_focus_workspace(document);
    let turn = read_focus_turn(document);
    apply_history_focus(document, workspace.as_deref(), turn);
    sync_focus_state_to_hash(document);
}

#[cfg(not(target_arch = "wasm32"))]
pub(super) fn sync_history_focus_from_dashboard(_document: &web_sys::Document) {}

#[cfg(target_arch = "wasm32")]
fn resolve_focus_workspace(workspaces: &[WorkspaceHistory], preferred: Option<&str>) -> Option<String> {
    if workspaces.is_empty() {
        return None;
    }

    if let Some(workspace_id) = preferred.and_then(normalize_focus_workspace) {
        if workspaces.iter().any(|workspace| workspace.workspace_id == workspace_id) {
            return Some(workspace_id);
        }
    }

    let mut refs = workspaces.iter().collect::<Vec<_>>();
    refs.sort_by(|a, b| compare_workspace_priority(a, b));
    refs.first().map(|workspace| workspace.workspace_id.clone())
}

#[cfg(target_arch = "wasm32")]
fn resolve_focus_turn(
    workspaces: &[WorkspaceHistory],
    workspace_id: Option<&str>,
    preferred: Option<u32>,
) -> Option<u32> {
    let target_workspace = workspace_id.and_then(|workspace| workspaces.iter().find(|entry| entry.workspace_id == workspace))?;

    if let Some(turn) = preferred.filter(|value| *value > 0) {
        if target_workspace.turns.iter().any(|row| row.turn == turn) {
            return Some(turn);
        }
    }

    target_workspace
        .turns
        .iter()
        .map(|row| row.turn)
        .max()
        .or_else(|| {
            if target_workspace.updated_turn > 0 {
                Some(target_workspace.updated_turn)
            } else {
                None
            }
        })
}

#[cfg(target_arch = "wasm32")]
fn apply_history_focus(document: &web_sys::Document, workspace: Option<&str>, turn: Option<u32>) {
    let workspace_key = workspace.and_then(normalize_focus_workspace);
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
            // Keep main logs fully readable; focus state is reflected in history chips/panels.
            let _ = el.class_list().remove_1("turn-dim");
            let _ = el.class_list().remove_1("turn-match");
        }
    }

    if let Ok(chips) = document.query_selector_all("#session-history .history-workspace-chip") {
        for idx in 0..chips.length() {
            let Some(node) = chips.item(idx) else {
                continue;
            };
            let Some(el) = node.dyn_ref::<web_sys::Element>() else {
                continue;
            };
            let chip_workspace = el.get_attribute("data-workspace").unwrap_or_default();
            let active = workspace_key
                .as_deref()
                .map(|target| chip_workspace == target)
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
            let group_workspace = el.get_attribute("data-workspace").unwrap_or_default();
            let visible = workspace_key
                .as_deref()
                .map(|target| group_workspace == target)
                .unwrap_or(false);
            if visible {
                let _ = el.class_list().remove_1("history-workspace-hidden");
            } else {
                let _ = el.class_list().add_1("history-workspace-hidden");
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
            let chip_workspace = el.get_attribute("data-workspace").unwrap_or_default();
            let chip_turn = el.get_attribute("data-turn").unwrap_or_default();
            let workspace_ok = workspace_key
                .as_deref()
                .map(|target| chip_workspace == target)
                .unwrap_or(false);
            let turn_ok = turn_key
                .as_deref()
                .map(|target| chip_turn == target)
                .unwrap_or(false);
            if workspace_ok && turn_ok {
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
            let panel_workspace = el.get_attribute("data-workspace").unwrap_or_default();
            let panel_turn = el.get_attribute("data-turn").unwrap_or_default();
            let workspace_ok = workspace_key
                .as_deref()
                .map(|target| panel_workspace == target)
                .unwrap_or(false);
            let turn_ok = match turn_key.as_deref() {
                Some(target) => panel_turn == target,
                None => panel_turn.trim().is_empty(),
            };
            if workspace_ok && turn_ok {
                let _ = el.class_list().remove_1("history-panel-hidden");
            } else {
                let _ = el.class_list().add_1("history-panel-hidden");
            }
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn bind_history_focus_controls(document: &web_sys::Document) {
    if let Ok(chips) = document.query_selector_all("#session-history .history-workspace-chip") {
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
            let workspace_raw = el.get_attribute("data-workspace").unwrap_or_default();
            let latest_turn_raw = el.get_attribute("data-latest-turn").unwrap_or_default();
            let cb = Closure::wrap(Box::new(move || {
                let Some(document) = web_sys::window().and_then(|w| w.document()) else {
                    return;
                };
                let workspace = normalize_focus_workspace(&workspace_raw);
                let turn = latest_turn_raw
                    .trim()
                    .parse::<u32>()
                    .ok()
                    .filter(|value| *value > 0);
                write_focus_workspace(&document, workspace.as_deref());
                write_focus_turn(&document, turn);
                apply_history_focus(&document, workspace.as_deref(), turn);
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
            let workspace_raw = el.get_attribute("data-workspace").unwrap_or_default();
            let turn_raw = el.get_attribute("data-turn").unwrap_or_default();
            let cb = Closure::wrap(Box::new(move || {
                let Some(document) = web_sys::window().and_then(|w| w.document()) else {
                    return;
                };
                let workspace = normalize_focus_workspace(&workspace_raw);
                let turn = turn_raw
                    .trim()
                    .parse::<u32>()
                    .ok()
                    .filter(|value| *value > 0);
                write_focus_workspace(&document, workspace.as_deref());
                write_focus_turn(&document, turn);
                apply_history_focus(&document, workspace.as_deref(), turn);
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

/// Render a per-workspace, per-turn timeline from TRPG stream events.
#[allow(unused_variables, unused_mut)]
pub fn update_session_history_dom(
    workspace_state: Res<WorkspaceState>,
    progress: Res<TurnProgressState>,
    mut readers: SessionHistoryReaders,
    mut cache: ResMut<SessionHistoryCache>,
) {
    let SessionHistoryReaders {
        mut narratives,
        mut dice_events,
        mut turn_events,
        mut progress_events,
        mut session_started,
    } = readers;

    #[cfg(not(target_arch = "wasm32"))]
    {
        for _ in turn_events.read() {}
        for _ in narratives.read() {}
        for _ in dice_events.read() {}
        for _ in progress_events.read() {}
        for _ in session_started.read() {}
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
        let mut base_workspace_id = normalize_workspace_id(&workspace_state.id);
        let current_workspace_fallback = normalize_workspace_id(&crate::config::current_workspace_id());
        if base_workspace_id == UNKNOWN_WORKSPACE_ID && current_workspace_fallback != UNKNOWN_WORKSPACE_ID {
            base_workspace_id = current_workspace_fallback;
        }
        let mut base_workspace_status = {
            let from_progress = normalize_workspace_status(&progress.workspace_status);
            if from_progress == "unknown" {
                normalize_workspace_status(&workspace_state.status)
            } else {
                from_progress
            }
        };
        if base_workspace_status == "unknown" {
            base_workspace_status = "active".to_string();
        }

        let mut current_turn = if progress.turn > 0 {
            progress.turn
        } else {
            workspace_state.turn.max(1)
        };
        let mut current_phase = if !progress.phase.is_empty() {
            progress.phase.clone()
        } else {
            workspace_state.phase.as_str().to_string()
        };

        let (workspace_idx, workspace_changed) = ensure_workspace_entry(
            &mut cache.workspaces,
            &base_workspace_id,
            &base_workspace_status,
            current_turn,
        );
        changed = changed || workspace_changed;
        if let Some(workspace) = cache.workspaces.get_mut(workspace_idx) {
            let (_, turn_changed) =
                ensure_turn_entry(&mut workspace.turns, current_turn, &current_phase);
            changed = changed || turn_changed;
        }

        for SessionStarted(event) in session_started.read() {
            let event_workspace_id = if event.workspace_id.trim().is_empty() {
                base_workspace_id.clone()
            } else {
                normalize_workspace_id(&event.workspace_id)
            };
            let incoming_session_id = event.session_id.trim().to_string();
            let event_phase = if current_phase.trim().is_empty() {
                "briefing".to_string()
            } else {
                current_phase.clone()
            };

            let (workspace_idx, workspace_changed) =
                ensure_workspace_entry(&mut cache.workspaces, &event_workspace_id, "active", 1);
            changed = changed || workspace_changed;

            let mut workspace_reset = false;
            if let Some(workspace) = cache.workspaces.get_mut(workspace_idx) {
                let has_progress_history = workspace.updated_turn > 1
                    || workspace.turns.iter().any(|row| row.turn > 1)
                    || workspace.turns.iter().any(|row| !row.events.is_empty());
                let should_reset = if incoming_session_id.is_empty() {
                    has_progress_history
                } else {
                    workspace.session_id != incoming_session_id
                };

                if should_reset {
                    workspace.session_id = incoming_session_id.clone();
                    workspace.turns.clear();
                    workspace.updated_turn = 1;
                    workspace.status = "active".to_string();
                    workspace_reset = true;
                } else if workspace.session_id.is_empty() && !incoming_session_id.is_empty() {
                    workspace.session_id = incoming_session_id.clone();
                    workspace_reset = true;
                }
            }
            changed = changed || workspace_reset;

            let detail = if incoming_session_id.is_empty() {
                "session started".to_string()
            } else {
                format!("session_id={}", incoming_session_id)
            };
            let (appended, updated) = append_event(
                &mut cache.workspaces,
                EventAppendInput {
                    workspace_id: &event_workspace_id,
                    workspace_status: "active",
                    turn: 1,
                    phase: &event_phase,
                    kind: "system",
                    actor: "",
                    title: "세션 시작",
                    detail: &detail,
                },
            );
            if !appended {
                bump_dedup_history(
                    &document,
                    &format!("{} | t1 | session.started | {}", event_workspace_id, detail),
                );
            }
            changed = changed || updated;
            current_turn = 1;
            current_phase = event_phase;
            base_workspace_status = "active".to_string();
        }

        for TurnAdvanced(event) in turn_events.read() {
            if event.turn > 0 {
                current_turn = event.turn;
            }
            if !event.phase.is_empty() {
                current_phase = event.phase.clone();
            }

            let event_workspace_id = if event.workspace_id.trim().is_empty() {
                base_workspace_id.clone()
            } else {
                normalize_workspace_id(&event.workspace_id)
            };

            let turn_detail = format!(
                "Turn {} ({})",
                current_turn,
                if current_phase.is_empty() {
                    "-"
                } else {
                    &current_phase
                }
            );
            let (appended, updated) = append_event(
                &mut cache.workspaces,
                EventAppendInput {
                    workspace_id: &event_workspace_id,
                    workspace_status: &base_workspace_status,
                    turn: current_turn,
                    phase: &current_phase,
                    kind: "turn",
                    actor: "",
                    title: "턴 진행",
                    detail: &turn_detail,
                },
            );
            if !appended {
                bump_dedup_history(
                    &document,
                    &format!(
                        "{} | t{} | turn | {}",
                        event_workspace_id, current_turn, current_phase
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
            let event_workspace_id = if event.workspace_id.trim().is_empty() {
                base_workspace_id.clone()
            } else {
                normalize_workspace_id(&event.workspace_id)
            };

            let (appended, updated) = append_event(
                &mut cache.workspaces,
                EventAppendInput {
                    workspace_id: &event_workspace_id,
                    workspace_status: &base_workspace_status,
                    turn: event_turn,
                    phase: &event_phase,
                    kind: "narrative",
                    actor: event.speaker.as_deref().unwrap_or(""),
                    title: "내러티브",
                    detail: &event.text,
                },
            );
            if !appended {
                bump_dedup_history(
                    &document,
                    &format!(
                        "{} | t{} | narrative | {}",
                        event_workspace_id,
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
            let event_workspace_id = if payload.workspace_id.trim().is_empty() {
                base_workspace_id.clone()
            } else {
                normalize_workspace_id(&payload.workspace_id)
            };

            let dice_detail = format!(
                "{} - {} (d20 {} + {} = {}, DC {})",
                payload.character,
                payload.action,
                payload.d20,
                payload.bonus,
                payload.total,
                payload.dc
            );
            let (appended, updated) = append_event(
                &mut cache.workspaces,
                EventAppendInput {
                    workspace_id: &event_workspace_id,
                    workspace_status: &base_workspace_status,
                    turn: event_turn,
                    phase: &current_phase,
                    kind: "dice",
                    actor: &payload.character,
                    title: "주사위",
                    detail: &dice_detail,
                },
            );
            if !appended {
                bump_dedup_history(
                    &document,
                    &format!(
                        "{} | t{} | dice | {}:{}",
                        event_workspace_id, event_turn, payload.character, payload.action
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
            let event_workspace_id = if event.workspace_id.trim().is_empty() {
                base_workspace_id.clone()
            } else {
                normalize_workspace_id(&event.workspace_id)
            };
            let event_status = {
                let normalized = normalize_workspace_status(&event.workspace_status);
                if normalized == "unknown" {
                    base_workspace_status.clone()
                } else {
                    normalized
                }
            };

            let (kind, actor, summary) = label_progress_event(event);
            let title = if summary.is_empty() {
                "turn progress"
            } else {
                &summary
            };
            let (appended, updated) = append_event(
                &mut cache.workspaces,
                EventAppendInput {
                    workspace_id: &event_workspace_id,
                    workspace_status: &event_status,
                    turn: event_turn,
                    phase: &event_phase,
                    kind,
                    actor: &actor,
                    title,
                    detail: &event.event_type,
                },
            );
            if !appended {
                bump_dedup_history(
                    &document,
                    &format!(
                        "{} | t{} | progress | {}",
                        event_workspace_id, event_turn, event.event_type
                    ),
                );
            }
            changed = changed || updated;
            current_turn = event_turn.max(1);
            current_phase = event_phase;
            base_workspace_status = event_status;
        }

        let (workspace_idx, workspace_changed) = ensure_workspace_entry(
            &mut cache.workspaces,
            &base_workspace_id,
            &base_workspace_status,
            current_turn,
        );
        changed = changed || workspace_changed;
        if let Some(workspace) = cache.workspaces.get_mut(workspace_idx) {
            let (_, turn_changed) =
                ensure_turn_entry(&mut workspace.turns, current_turn, &current_phase);
            changed = changed || turn_changed;
        }

        if !changed {
            return;
        }

        let current_workspace_id = crate::config::current_workspace_id();
        history.set_inner_html(&render_session_history_html(&cache.workspaces, &current_workspace_id));
        bind_history_focus_controls(&document);

        let preferred_workspace = read_focus_workspace(&document).or_else(|| Some(base_workspace_id.clone()));
        let preferred_turn = read_focus_turn(&document).or(Some(current_turn.max(1)));

        let focus_workspace = resolve_focus_workspace(&cache.workspaces, preferred_workspace.as_deref());
        let focus_turn = resolve_focus_turn(&cache.workspaces, focus_workspace.as_deref(), preferred_turn);

        write_focus_workspace(&document, focus_workspace.as_deref());
        write_focus_turn(&document, focus_turn);
        apply_history_focus(&document, focus_workspace.as_deref(), focus_turn);
        sync_focus_state_to_hash(&document);
    }
}
