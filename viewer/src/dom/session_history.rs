//! TRPG session timeline.
//!
//! Captures narrative, dice, and turn-progress events into per-turn history
//! and renders them as a compact expandable timeline in the bottom panel.

use bevy::prelude::*;

use crate::game::events::{DiceRolled, NarrativeReceived, TurnAdvanced, TurnProgressUpdated};
use crate::game::state::{RoomState, TurnProgressState};

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

#[derive(Resource, Default)]
pub struct SessionHistoryCache {
    last_room_id: String,
    turns: Vec<TurnHistory>,
}

#[cfg(target_arch = "wasm32")]
fn sanitize_text(raw: &str) -> String {
    raw.chars()
        .filter(|ch| {
            let code = *ch as u32;
            !ch.is_control() && code != 0x00ad && code != 0x200b && code != 0xfeff
        })
        .collect()
}

#[cfg(target_arch = "wasm32")]
fn escape_html(raw: &str) -> String {
    sanitize_text(raw)
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn sanitize_key(raw: &str) -> String {
    raw.trim().to_ascii_lowercase()
}

#[cfg(target_arch = "wasm32")]
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

fn ensure_turn_entry(turns: &mut Vec<TurnHistory>, turn: u32, phase: &str) -> usize {
    for (idx, row) in turns.iter_mut().enumerate() {
        if row.turn == turn {
            if !phase.trim().is_empty() {
                row.phase = phase.to_string();
            }
            return idx;
        }
    }
    turns.push(TurnHistory {
        turn,
        phase: phase.to_string(),
        events: Vec::new(),
    });
    turns.sort_by_key(|row| row.turn);
    while turns.len() > MAX_TURNS_TO_KEEP {
        let _ = turns.remove(0);
    }
    turns.iter().position(|row| row.turn == turn).unwrap_or(0)
}

fn append_event(turns: &mut Vec<TurnHistory>, turn: u32, phase: &str, kind: &str, actor: &str, title: &str, detail: &str) {
    let idx = ensure_turn_entry(turns, turn, phase);
    let Some(row) = turns.get_mut(idx) else {
        return;
    };
    row.events.push(HistoryEvent {
        kind: kind.to_string(),
        actor: actor.to_string(),
        title: title.to_string(),
        detail: detail.to_string(),
    });
    if row.events.len() > MAX_EVENTS_PER_TURN {
        let overflow = row.events.len() - MAX_EVENTS_PER_TURN;
        row.events.drain(0..overflow);
    }
}

fn label_progress_event(payload: &crate::game::events::TurnProgressPayload) -> (&'static str, String, String) {
    let actor = payload.actor_id.trim();
    let label = match payload.event_type.as_str() {
        "turn.started" => "턴 시작",
        "phase.changed" => "페이즈 변경",
        "narration.posted" => "내레이션",
        "turn.action.proposed" => "행동 제안",
        "turn.timeout" => "턴 타임아웃",
        "keeper.unavailable" => "Keeper 사용 불가",
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
fn render_session_history_html(turns: &[TurnHistory]) -> String {
    if turns.is_empty() {
        return "<div class=\"session-history-empty\">아직 세션 히스토리가 없습니다.</div>".to_string();
    }

    let mut html = String::new();
    for (idx, row) in turns.iter().rev().enumerate() {
        let open = if idx == 0 { " open" } else { "" };
        let phase = if row.phase.is_empty() {
            "unknown".to_string()
        } else {
            row.phase.clone()
        };
        let row_events = if row.events.is_empty() {
            "<li class=\"history-event-none\">이 턴에는 기록이 없습니다.</li>".to_string()
        } else {
            row.events
                .iter()
                .map(|ev| {
                    let actor = escape_html(&ev.actor);
                    let title = escape_html(&ev.title);
                    let detail = escape_html(&ev.detail);
                    let class = history_kind_class(&sanitize_key(&ev.kind));
                    if actor.is_empty() {
                        if detail.is_empty() {
                            format!(
                                r#"<li class="history-event {class}"><span class="history-kind">{title}</span><span class="history-detail">-</span></li>"#
                            )
                        } else {
                            format!(
                                r#"<li class="history-event {class}"><span class="history-kind">{title}</span><span class="history-detail">{detail}</span></li>"#
                            )
                        }
                    } else {
                        format!(
                            r#"<li class="history-event {class}"><span class="history-kind">{title}</span><span class="history-actor">{actor}</span><span class="history-detail">{detail}</span></li>"#
                        )
                    }
                })
                .collect::<Vec<_>>()
                .join("")
        };
        html.push_str(&format!(
            "<details class=\"history-turn\"{open}><summary><span class=\"history-turn-header\">TURN {turn} · {phase}</span><span class=\"history-event-count\">{count}</span></summary><ul class=\"history-event-list\">{events}</ul></details>",
            open = open,
            turn = row.turn,
            phase = sanitize_text(&phase),
            count = row.events.len(),
            events = row_events
        ));
    }
    html
}

/// Render a compact per-turn timeline from TRPG stream events.
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
        if cache.last_room_id != room_state.id {
            cache.last_room_id = room_state.id.clone();
            cache.turns.clear();
            changed = true;
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

        for TurnAdvanced(event) in turn_events.read() {
            if event.turn > 0 {
                current_turn = event.turn;
            }
            if !event.phase.is_empty() {
                current_phase = event.phase.clone();
            }
            append_event(
                &mut cache.turns,
                current_turn,
                &current_phase,
                "turn",
                "",
                "턴 진행",
                &format!("Turn {} ({})", current_turn, if current_phase.is_empty() { "-" } else { &current_phase }),
            );
            changed = true;
        }

        for NarrativeReceived(event) in narratives.read() {
            append_event(
                &mut cache.turns,
                current_turn,
                &current_phase,
                "narrative",
                event.speaker.as_deref().unwrap_or(""),
                "내러티브",
                &event.text,
            );
            changed = true;
        }

        for DiceRolled(payload) in dice_events.read() {
            let turn = if payload.turn > 0 { payload.turn } else { current_turn };
            if turn > 0 {
                current_turn = turn;
            }
            append_event(
                &mut cache.turns,
                current_turn,
                &current_phase,
                "dice",
                &payload.character,
                "주사위",
                &format!(
                    "{} — {} (d20 {} + {} = {}, DC {})",
                    payload.character,
                    payload.action,
                    payload.d20,
                    payload.bonus,
                    payload.total,
                    payload.dc
                ),
            );
            changed = true;
        }

        for TurnProgressUpdated(event) in progress_events.read() {
            if event.turn > 0 {
                current_turn = event.turn;
            }
            if !event.phase.is_empty() {
                current_phase = event.phase.clone();
            }
            let (kind, actor, summary) = label_progress_event(&event);
            append_event(
                &mut cache.turns,
                current_turn,
                &current_phase,
                kind,
                &actor,
                if summary.is_empty() { "turn progress" } else { &summary },
                &event.event_type,
            );
            changed = true;
        }

        if !changed {
            return;
        }

        history.set_inner_html(&render_session_history_html(&cache.turns));
    }
}
