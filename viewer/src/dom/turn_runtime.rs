use bevy::prelude::*;
use std::collections::BTreeSet;

use crate::game::components::Actor;
use crate::game::lifecycle::TrpgLifecycleState;
use crate::game::round_runner::RoundRunner;
use crate::game::state::{ConnectionStatus, RoomState, TurnProgressState};

/// Tracks last-rendered runtime status snapshot to avoid redundant DOM updates.
#[derive(Resource, Default)]
pub struct TurnRuntimeCache {
    pub last_snapshot: String,
}

#[cfg(target_arch = "wasm32")]
use super::escape::html_escape;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;
#[cfg(target_arch = "wasm32")]
use web_sys::HtmlInputElement;

#[cfg(target_arch = "wasm32")]
fn pretty_phase(phase: &str) -> String {
    let normalized = phase.trim().replace('_', " ");
    if normalized.is_empty() {
        "-".to_string()
    } else {
        normalized
    }
}

#[cfg(target_arch = "wasm32")]
fn room_status_class(state: TrpgLifecycleState) -> &'static str {
    match state {
        TrpgLifecycleState::Running => "status-active",
        TrpgLifecycleState::Stopped => "status-paused",
        TrpgLifecycleState::Ended => "status-ended",
        TrpgLifecycleState::Unavailable => "status-unavailable",
        TrpgLifecycleState::Loading => "status-loading",
        TrpgLifecycleState::Lobby | TrpgLifecycleState::Unknown => "status-idle",
    }
}

#[cfg(target_arch = "wasm32")]
fn room_status_label(state: TrpgLifecycleState) -> &'static str {
    state.label_ko()
}

fn connection_status_class(status: &ConnectionStatus) -> &'static str {
    match status {
        ConnectionStatus::Connected => "status-active",
        ConnectionStatus::Connecting | ConnectionStatus::Reconnecting(_, _) => "status-loading",
        ConnectionStatus::Disconnected => "status-idle",
        ConnectionStatus::Failed => "status-error",
    }
}

fn connection_status_label(status: &ConnectionStatus) -> &'static str {
    match status {
        ConnectionStatus::Connected => "연결됨",
        ConnectionStatus::Connecting => "연결 중",
        ConnectionStatus::Reconnecting(_, _) => "재연결 중",
        ConnectionStatus::Disconnected => "연결 끊김",
        ConnectionStatus::Failed => "연결 실패",
    }
}

fn normalize_phase_for_sync(phase: &str) -> String {
    phase.trim().to_ascii_lowercase().replace('-', "_")
}

fn phase_is_aggregate_round(phase: &str) -> bool {
    normalize_phase_for_sync(phase) == "round"
}

fn phase_matches_for_sync(room_phase: &str, progress_phase: &str) -> bool {
    let room_norm = normalize_phase_for_sync(room_phase);
    let progress_norm = normalize_phase_for_sync(progress_phase);
    if room_norm == progress_norm {
        return true;
    }
    if room_norm.is_empty() || progress_norm.is_empty() {
        return false;
    }
    phase_is_aggregate_round(&room_norm) || phase_is_aggregate_round(&progress_norm)
}

fn compact_reason_text(raw: &str) -> String {
    let compact = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    const MAX_REASON_CHARS: usize = 72;
    if compact.chars().count() <= MAX_REASON_CHARS {
        compact
    } else {
        let mut short = compact.chars().take(MAX_REASON_CHARS).collect::<String>();
        short.push_str("...");
        short
    }
}

#[cfg(target_arch = "wasm32")]
#[derive(Clone, Copy)]
enum FlowStepState {
    Done,
    Active,
    Wait,
    Error,
}

#[cfg(target_arch = "wasm32")]
impl FlowStepState {
    fn css(self) -> &'static str {
        match self {
            Self::Done => "is-done",
            Self::Active => "is-active",
            Self::Wait => "is-wait",
            Self::Error => "is-error",
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn actor_state_is_done(state: &str) -> bool {
    matches!(
        state.trim().to_ascii_lowercase().as_str(),
        "ok" | "timeout" | "unavailable"
    )
}

#[cfg(target_arch = "wasm32")]
fn actor_state_is_error(state: &str) -> bool {
    matches!(
        state.trim().to_ascii_lowercase().as_str(),
        "timeout" | "unavailable"
    )
}

#[cfg(target_arch = "wasm32")]
fn render_agent_round_flow(document: &web_sys::Document, progress: &TurnProgressState) {
    let Some(el) = document.get_element_by_id("agent-round-flow") else {
        return;
    };

    let player_ids = progress
        .actor_order
        .iter()
        .filter(|actor_id| actor_id.as_str() != "dm")
        .map(|actor_id| actor_id.as_str())
        .collect::<Vec<_>>();
    let player_total = player_ids.len();

    let mut player_done = 0usize;
    let mut player_success = 0usize;
    let mut player_error = 0usize;
    for actor_id in &player_ids {
        let state = progress
            .actor_states
            .get(*actor_id)
            .map(String::as_str)
            .unwrap_or("pending");
        if actor_state_is_done(state) {
            player_done += 1;
        }
        if state.trim().eq_ignore_ascii_case("ok") {
            player_success += 1;
        }
        if actor_state_is_error(state) {
            player_error += 1;
        }
    }

    let quorum_required = if player_total == 0 {
        0
    } else {
        std::cmp::max(1, (player_total + 1) / 2)
    };
    let quorum_met = player_success >= quorum_required;
    let quorum_impossible =
        player_success + (player_total.saturating_sub(player_done)) < quorum_required;

    let dm_state = progress
        .actor_states
        .get("dm")
        .map(String::as_str)
        .unwrap_or("pending")
        .trim()
        .to_ascii_lowercase();
    let dm_done = actor_state_is_done(&dm_state);
    let dm_error = actor_state_is_error(&dm_state);
    let phase_label = pretty_phase(&progress.phase);
    let current_actor = if progress.current_actor.trim().is_empty() {
        "-".to_string()
    } else {
        progress.current_actor.trim().to_string()
    };
    let flow_head = format!(
        "TURN {} · PHASE {} · 현재 {}",
        progress.turn, phase_label, current_actor
    );

    let prep_state = if player_total > 0 {
        FlowStepState::Done
    } else if !progress.actor_order.is_empty() {
        FlowStepState::Active
    } else {
        FlowStepState::Wait
    };
    let prep_text = if player_total > 0 {
        format!("DM/플레이어 선택 완료 ({}명)", player_total)
    } else if !progress.actor_order.is_empty() {
        "파티 구성/동기화 중".to_string()
    } else {
        "새 게임에서 DM/플레이어 선택 대기".to_string()
    };

    let player_state = if player_total == 0 {
        FlowStepState::Wait
    } else if player_error > 0 {
        FlowStepState::Error
    } else if player_done >= player_total {
        FlowStepState::Done
    } else if player_done > 0 {
        FlowStepState::Active
    } else {
        FlowStepState::Wait
    };
    let player_text = if player_total == 0 {
        "플레이어 미선택".to_string()
    } else if player_done == 0 {
        format!(
            "응답 대기 {}/{} · 라운드 실행 필요",
            player_done, player_total
        )
    } else {
        format!(
            "응답 {}/{} · 성공 {} · 이슈 {}",
            player_done, player_total, player_success, player_error
        )
    };

    let quorum_state = if player_total == 0 {
        FlowStepState::Wait
    } else if quorum_met {
        FlowStepState::Done
    } else if quorum_impossible {
        FlowStepState::Error
    } else if player_done > 0 {
        FlowStepState::Active
    } else {
        FlowStepState::Wait
    };
    let quorum_text = if player_total == 0 {
        "파티 선택 후 계산".to_string()
    } else {
        format!(
            "성공 {} / 필요 {} · 남은 응답 {}",
            player_success,
            quorum_required,
            player_total.saturating_sub(player_done)
        )
    };

    let dm_step_state = if player_total == 0 {
        FlowStepState::Wait
    } else if !quorum_met && quorum_impossible {
        FlowStepState::Error
    } else if !quorum_met {
        FlowStepState::Wait
    } else if dm_error {
        FlowStepState::Error
    } else if dm_done {
        FlowStepState::Done
    } else if dm_state == "thinking" || progress.current_actor.trim() == "dm" {
        FlowStepState::Active
    } else {
        FlowStepState::Wait
    };
    let dm_text = if player_total == 0 {
        "쿼럼 이후 실행".to_string()
    } else if !quorum_met {
        "플레이어 응답/쿼럼 대기".to_string()
    } else if dm_done {
        format!("DM 처리 완료 ({})", dm_state)
    } else if dm_state == "thinking" {
        "DM 응답 생성 중 (thinking)".to_string()
    } else {
        "DM 실행 대기 (라운드 실행)".to_string()
    };

    let resolve_state = if player_total == 0 {
        FlowStepState::Wait
    } else if dm_error {
        FlowStepState::Error
    } else if dm_done
        && (progress.last_event == "turn.started"
            || progress.last_event == "phase.changed"
            || progress.last_event == "session.outcome")
    {
        FlowStepState::Done
    } else if dm_done {
        FlowStepState::Active
    } else {
        FlowStepState::Wait
    };
    let resolve_text = match progress.last_event.as_str() {
        "turn.started" => format!("turn.started 수신 · 다음 TURN {} 진행", progress.turn),
        "phase.changed" => "phase.changed 반영 완료".to_string(),
        "session.outcome" => "세션 종료 결과 반영".to_string(),
        "" => "이벤트 대기".to_string(),
        other => format!("이벤트 반영 대기 · {}", other),
    };

    let step_html = |title: &str, state: FlowStepState, text: String| {
        format!(
            "<div class=\"agent-flow-step {class}\"><span class=\"s-k\">{title}</span><span class=\"s-v\">{text}</span></div>",
            class = state.css(),
            title = html_escape(title),
            text = html_escape(&text),
        )
    };

    let html = [
        step_html("1 준비", prep_state, prep_text),
        step_html("2 플레이어", player_state, player_text),
        step_html("3 쿼럼", quorum_state, quorum_text),
        step_html("4 DM", dm_step_state, dm_text),
        step_html("5 반영", resolve_state, resolve_text),
    ]
    .join("");

    el.set_inner_html(&format!(
        "<div class=\"agent-flow-head\">{}</div><div class=\"agent-flow-track\">{}</div>",
        html_escape(&flow_head),
        html
    ));
}

fn ordered_actor_ids_for_issue_scan(progress: &TurnProgressState) -> Vec<String> {
    let mut ordered = Vec::new();
    let mut seen = BTreeSet::new();

    for actor_id in &progress.actor_order {
        let actor_id = actor_id.trim();
        if !actor_id.is_empty() && seen.insert(actor_id.to_string()) {
            ordered.push(actor_id.to_string());
        }
    }
    for actor_id in progress.actor_states.keys() {
        let actor_id = actor_id.trim();
        if !actor_id.is_empty() && seen.insert(actor_id.to_string()) {
            ordered.push(actor_id.to_string());
        }
    }
    for actor_id in progress.actor_reasons.keys() {
        let actor_id = actor_id.trim();
        if !actor_id.is_empty() && seen.insert(actor_id.to_string()) {
            ordered.push(actor_id.to_string());
        }
    }

    ordered
}

fn summarize_actor_issues(progress: &TurnProgressState) -> (String, bool) {
    let mut issues = Vec::new();
    for actor_id in ordered_actor_ids_for_issue_scan(progress) {
        let state = progress
            .actor_states
            .get(&actor_id)
            .map(|v| v.trim().to_ascii_lowercase())
            .unwrap_or_default();
        let reason = progress
            .actor_reasons
            .get(&actor_id)
            .map(|v| compact_reason_text(v))
            .unwrap_or_default();
        let is_issue_state = matches!(state.as_str(), "timeout" | "unavailable");
        if !is_issue_state && reason.is_empty() {
            continue;
        }
        let state_label = if is_issue_state {
            state.as_str()
        } else {
            "issue"
        };
        if reason.is_empty() {
            issues.push(format!("{}: {}", actor_id, state_label));
        } else {
            issues.push(format!("{}: {} ({})", actor_id, state_label, reason));
        }
    }

    if issues.is_empty() {
        ("-".to_string(), false)
    } else {
        (issues.join(" · "), true)
    }
}

fn build_next_action_hint(
    lifecycle: TrpgLifecycleState,
    runner_running: bool,
    current_actor: &str,
    has_actor_issues: bool,
) -> String {
    if runner_running {
        return "자동 진행 중입니다. 이벤트 수신을 기다리세요.".to_string();
    }
    if !lifecycle.accepts_player_input() {
        return match lifecycle {
            TrpgLifecycleState::Loading => {
                "로딩 중입니다. 상태 동기화 완료를 기다리세요.".to_string()
            }
            TrpgLifecycleState::Stopped => {
                "세션이 멈춰 있습니다. 라운드 실행으로 재개하세요.".to_string()
            }
            TrpgLifecycleState::Ended => {
                "세션이 종료되었습니다. 새 게임으로 시작하세요.".to_string()
            }
            TrpgLifecycleState::Unavailable => {
                "엔진/키퍼 연결을 복구한 뒤 다시 시도하세요.".to_string()
            }
            TrpgLifecycleState::Lobby => "세션을 시작한 뒤 라운드 실행을 누르세요.".to_string(),
            TrpgLifecycleState::Unknown => "상태 확인 후 라운드 실행을 다시 누르세요.".to_string(),
            TrpgLifecycleState::Running => "진행 상태를 확인하세요.".to_string(),
        };
    }
    if has_actor_issues {
        return "keeper 상태를 확인한 뒤 라운드 실행을 다시 누르세요.".to_string();
    }

    let actor = current_actor.trim();
    if actor.is_empty() || actor == "-" {
        "라운드 실행을 누르거나 플레이어 액션을 입력하세요.".to_string()
    } else {
        format!("{} 응답을 기다리는 중입니다.", actor)
    }
}

fn build_flow_banner(
    lifecycle: TrpgLifecycleState,
    connection: &ConnectionStatus,
    runner_running: bool,
    has_actor_issues: bool,
    current_actor: &str,
    next_action: &str,
) -> (&'static str, &'static str, String) {
    match connection {
        ConnectionStatus::Failed | ConnectionStatus::Disconnected => (
            "연결 오류",
            "is-error",
            "엔진 연결이 끊겼습니다. 연결 복구 후 다시 시도하세요.".to_string(),
        ),
        ConnectionStatus::Connecting | ConnectionStatus::Reconnecting(_, _) => (
            "연결 중",
            "is-waiting",
            "엔진 연결을 복구하고 있습니다. 잠시 기다려주세요.".to_string(),
        ),
        ConnectionStatus::Connected => match lifecycle {
            TrpgLifecycleState::Unavailable => (
                "복구 필요",
                "is-error",
                "세션을 계속할 수 없습니다. keeper/엔진 상태를 확인하세요.".to_string(),
            ),
            TrpgLifecycleState::Ended => (
                "세션 종료",
                "is-idle",
                "현재 세션이 종료되었습니다. 새 게임으로 다시 시작하세요.".to_string(),
            ),
            TrpgLifecycleState::Stopped => (
                "일시 정지",
                "is-alert",
                "세션이 멈춰 있습니다. 라운드 실행으로 다시 진행할 수 있습니다.".to_string(),
            ),
            TrpgLifecycleState::Loading => (
                "세션 준비",
                "is-waiting",
                "초기화/동기화 중입니다. 완료 후 라운드를 실행하세요.".to_string(),
            ),
            TrpgLifecycleState::Lobby | TrpgLifecycleState::Unknown => (
                "로비",
                "is-idle",
                "새 게임을 시작하거나 실행 가능한 방으로 이동하세요.".to_string(),
            ),
            TrpgLifecycleState::Running => {
                if runner_running {
                    (
                        "자동 진행",
                        "is-running",
                        format!("AI 라운드 자동 순환 중 · {}", next_action),
                    )
                } else if has_actor_issues {
                    (
                        "주의",
                        "is-alert",
                        format!("응답 이슈 감지 · {}", next_action),
                    )
                } else if !current_actor.trim().is_empty() && current_actor.trim() != "-" {
                    (
                        "진행 중",
                        "is-running",
                        format!("{} 턴 처리 중 · {}", current_actor.trim(), next_action),
                    )
                } else {
                    (
                        "대기",
                        "is-waiting",
                        format!("다음 액션 대기 · {}", next_action),
                    )
                }
            }
        },
    }
}

#[cfg(target_arch = "wasm32")]
fn set_ops_hud_value(document: &web_sys::Document, id: &str, text: &str, status_class: &str) {
    let Some(el) = document.get_element_by_id(id) else {
        return;
    };
    let class_name = if status_class.trim().is_empty() {
        "ops-v".to_string()
    } else {
        format!("ops-v {}", status_class.trim())
    };
    el.set_text_content(Some(text));
    el.set_class_name(&class_name);
}

#[cfg(target_arch = "wasm32")]
fn round_plan_storage_key(room_id: &str) -> String {
    format!("masc.viewer.round_plan.{}", room_id.trim())
}

#[cfg(target_arch = "wasm32")]
fn restore_round_plan_inputs(document: &web_sys::Document, room_id: &str) {
    let Some(storage) = web_sys::window()
        .and_then(|w| w.local_storage().ok())
        .flatten()
    else {
        return;
    };
    let Ok(Some(raw)) = storage.get_item(&round_plan_storage_key(room_id)) else {
        return;
    };
    let Ok(payload) = serde_json::from_str::<serde_json::Value>(&raw) else {
        return;
    };

    if let Some(dm) = payload.get("dm").and_then(serde_json::Value::as_str) {
        if let Some(dm_input) = document
            .get_element_by_id("round-run-dm")
            .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        {
            if dm_input.value().trim().is_empty() && !dm.trim().is_empty() {
                dm_input.set_value(dm.trim());
            }
        }
    }
    if let Some(players) = payload.get("players").and_then(serde_json::Value::as_str) {
        if let Some(players_input) = document
            .get_element_by_id("round-run-players")
            .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        {
            if players_input.value().trim().is_empty() && !players.trim().is_empty() {
                players_input.set_value(players.trim());
            }
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn persist_round_plan_inputs(document: &web_sys::Document, room_id: &str) {
    let Some(storage) = web_sys::window()
        .and_then(|w| w.local_storage().ok())
        .flatten()
    else {
        return;
    };

    let dm = document
        .get_element_by_id("round-run-dm")
        .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        .map(|input| input.value())
        .unwrap_or_default();
    let players = document
        .get_element_by_id("round-run-players")
        .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        .map(|input| input.value())
        .unwrap_or_default();

    if dm.trim().is_empty() && players.trim().is_empty() {
        return;
    }

    let payload = serde_json::json!({
        "dm": dm.trim(),
        "players": players.trim(),
    });
    let _ = storage.set_item(&round_plan_storage_key(room_id), &payload.to_string());
}

/// Render live TRPG runtime progress:
/// room/turn/phase, current thinker, next actor, last outcome, and party survival.
pub fn update_turn_runtime_dom(
    room_state: Res<RoomState>,
    progress: Res<TurnProgressState>,
    connection: Res<ConnectionStatus>,
    runner: Option<Res<RoundRunner>>,
    actors: Query<&Actor>,
    mut cache: ResMut<TurnRuntimeCache>,
) {
    let room_status_raw = if !progress.room_status.trim().is_empty() {
        progress.room_status.trim().to_string()
    } else if !room_state.status.trim().is_empty() {
        room_state.status.trim().to_string()
    } else {
        "unknown".to_string()
    };
    let lifecycle =
        TrpgLifecycleState::from_room_progress(&room_state.status, &progress.room_status);
    let room_status_key = crate::game::lifecycle::normalize_status(&room_status_raw);
    let turn = if progress.turn > 0 {
        progress.turn
    } else if room_state.turn > 0 {
        room_state.turn
    } else {
        1
    };
    let phase = if !progress.phase.trim().is_empty() {
        progress.phase.trim().to_string()
    } else {
        room_state.phase.as_str().to_string()
    };

    let current_actor = if !progress.current_actor.trim().is_empty() {
        progress.current_actor.trim().to_string()
    } else {
        "-".to_string()
    };
    let next_actor = if !progress.next_actor.trim().is_empty() {
        progress.next_actor.trim().to_string()
    } else {
        "-".to_string()
    };
    let last_result = if !progress.last_actor.trim().is_empty() {
        format!(
            "{} ({})",
            progress.last_actor.trim(),
            if progress.last_result.trim().is_empty() {
                "ok"
            } else {
                progress.last_result.trim()
            }
        )
    } else {
        "-".to_string()
    };

    let (alive_party, total_party) = actors.iter().filter(|actor| actor.id != "dm").fold(
        (0_i32, 0_i32),
        |(alive, total), actor| {
            (
                alive + if !actor.is_dead && actor.hp > 0 { 1 } else { 0 },
                total + 1,
            )
        },
    );
    let party_status = if total_party <= 0 {
        "-".to_string()
    } else if alive_party <= 0 {
        "WIPE".to_string()
    } else {
        format!("{}/{} 생존", alive_party, total_party)
    };
    let (issues_summary, has_actor_issues) = summarize_actor_issues(&progress);

    let current_status = if !lifecycle.accepts_player_input() {
        lifecycle.label_ko()
    } else if current_actor != "-" {
        "응답 생성 중"
    } else {
        "대기 중"
    };

    let input_status = if lifecycle.accepts_player_input() {
        "입력 가능"
    } else {
        "입력 잠금"
    };

    let room_turn_for_sync = if room_state.turn > 0 {
        room_state.turn
    } else {
        turn
    };
    let room_phase_for_sync = room_state.phase.as_str().to_string();
    let progress_turn_for_sync = if progress.turn > 0 {
        progress.turn
    } else {
        turn
    };
    let progress_phase_for_sync = if progress.phase.trim().is_empty() {
        room_phase_for_sync.clone()
    } else {
        progress.phase.trim().to_string()
    };
    let turn_mismatch = room_turn_for_sync != progress_turn_for_sync;
    let phase_mismatch = !phase_matches_for_sync(&room_phase_for_sync, &progress_phase_for_sync);

    let (sync_state, sync_class) = if turn_mismatch || phase_mismatch {
        let mut reasons = Vec::new();
        if turn_mismatch {
            reasons.push(format!(
                "turn {}≠{}",
                room_turn_for_sync, progress_turn_for_sync
            ));
        }
        if phase_mismatch {
            reasons.push(format!(
                "phase {}≠{}",
                room_phase_for_sync, progress_phase_for_sync
            ));
        }
        (format!("불일치: {}", reasons.join(" · ")), "status-error")
    } else if progress.last_event.trim().is_empty() {
        ("이벤트 대기".to_string(), "status-idle")
    } else {
        (
            format!("정상 · {}", progress.last_event.trim()),
            "status-active",
        )
    };

    let control_state = if lifecycle.accepts_player_input() {
        if current_actor != "-" {
            "수동 실행 가능 · 액터 처리 중".to_string()
        } else {
            "수동 실행 가능".to_string()
        }
    } else {
        lifecycle.label_ko().to_string()
    };

    let (runner_running, runner_rounds, runner_last_result) = if let Some(runner) = runner.as_ref()
    {
        let running = runner.running.load(std::sync::atomic::Ordering::SeqCst);
        let rounds = runner
            .rounds_completed
            .lock()
            .ok()
            .map(|guard| *guard)
            .unwrap_or(0);
        let last = runner
            .last_result
            .lock()
            .ok()
            .and_then(|guard| guard.clone())
            .unwrap_or_default();
        (running, rounds, last)
    } else {
        (false, 0, String::new())
    };

    let runner_state = if runner_running {
        format!("자동 진행 {} 라운드", runner_rounds)
    } else {
        "대기".to_string()
    };
    let next_action =
        build_next_action_hint(lifecycle, runner_running, &current_actor, has_actor_issues);
    let (flow_state, flow_class, flow_detail) = build_flow_banner(
        lifecycle,
        &connection,
        runner_running,
        has_actor_issues,
        &current_actor,
        &next_action,
    );

    let connection_label = connection_status_label(&connection);
    let connection_class = connection_status_class(&connection);

    #[cfg(not(target_arch = "wasm32"))]
    let _ = (
        &sync_class,
        &control_state,
        &runner_last_result,
        &flow_state,
        &flow_class,
        &flow_detail,
    );

    let snapshot = format!(
        "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}",
        room_status_key,
        turn,
        phase,
        current_actor,
        next_actor,
        last_result,
        party_status,
        current_status,
        input_status,
        connection_label,
        connection_class,
        sync_state,
        runner_state,
        progress.last_event,
        issues_summary,
        next_action,
        flow_state,
        flow_class,
        flow_detail,
    );
    if cache.last_snapshot == snapshot {
        return;
    }
    cache.last_snapshot = snapshot;

    #[cfg(target_arch = "wasm32")]
    {
        let Some(document) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let Some(el) = document.get_element_by_id("turn-runtime") else {
            return;
        };

        let room_class = room_status_class(lifecycle);
        let party_class = if total_party > 0 && alive_party <= 0 {
            "status-wipe"
        } else {
            "status-active"
        };
        let issues_class = if has_actor_issues {
            "status-error"
        } else {
            "status-idle"
        };
        let input_class = if lifecycle.accepts_player_input() {
            "status-active"
        } else {
            room_class
        };

        if let Some(room_status_el) = document.get_element_by_id("room-status") {
            let room_id = crate::config::current_room_id();
            room_status_el.set_text_content(Some(&format!(
                "현재 게임 {} · {}",
                room_id,
                lifecycle.label_ko()
            )));
            let _ = room_status_el.set_attribute("data-lifecycle", lifecycle.css_class());
            let _ = room_status_el.set_attribute(
                "title",
                &format!(
                    "{} | 턴 {} | 페이즈 {} | raw {}",
                    lifecycle.help_text(),
                    turn,
                    phase,
                    room_status_key
                ),
            );
        }

        let room_id = crate::config::current_room_id();
        let mut room_switched = false;
        if let Some(dashboard) = document.get_element_by_id("dashboard") {
            let previous_room = dashboard
                .get_attribute("data-round-plan-room")
                .unwrap_or_default();
            if previous_room.trim() != room_id {
                room_switched = true;
                let _ = dashboard.set_attribute("data-round-plan-room", &room_id);
            }
        }

        if room_switched {
            if let Some(dm_input) = document
                .get_element_by_id("round-run-dm")
                .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
            {
                dm_input.set_value("");
            }
            if let Some(players_input) = document
                .get_element_by_id("round-run-players")
                .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
            {
                players_input.set_value("");
            }
            if let Some(claimed_actor) = document
                .get_element_by_id("claimed-actor-id")
                .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
            {
                claimed_actor.set_value("");
            }
            if let Some(claimed_keeper) = document
                .get_element_by_id("claimed-keeper")
                .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
            {
                claimed_keeper.set_value("");
            }
            if let Some(claimed_room) = document
                .get_element_by_id("claimed-room-id")
                .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
            {
                claimed_room.set_value("");
            }
            if let Some(el) = document.get_element_by_id("action-panel") {
                let _ = el.set_attribute("style", "display: none;");
            }
            if let Some(el) = document.get_element_by_id("join-panel") {
                let _ = el.remove_attribute("style");
            }
            if let Some(el) = document.get_element_by_id("player-actor-id") {
                el.set_text_content(Some(""));
            }
            if let Some(summary) = document.get_element_by_id("round-run-summary") {
                summary.set_text_content(Some(""));
                let _ = summary.set_attribute("style", "display:none");
            }
            restore_round_plan_inputs(&document, &room_id);
        }

        set_ops_hud_value(&document, "ops-room-id", &room_id, room_class);
        set_ops_hud_value(
            &document,
            "ops-session-state",
            lifecycle.label_ko(),
            room_class,
        );
        set_ops_hud_value(
            &document,
            "ops-round-phase",
            &format!("T{} / {}", turn, pretty_phase(&phase)),
            room_class,
        );
        set_ops_hud_value(
            &document,
            "ops-connection-state",
            connection_label,
            connection_class,
        );
        set_ops_hud_value(
            &document,
            "ops-control-state",
            &control_state,
            if lifecycle.accepts_player_input() {
                "status-active"
            } else {
                room_class
            },
        );
        set_ops_hud_value(&document, "ops-sync-state", &sync_state, sync_class);
        if let Some(flow_banner) = document.get_element_by_id("turn-flow-banner") {
            let _ = flow_banner.set_attribute("class", &format!("turn-flow-banner {}", flow_class));
            let html = format!(
                "<span class=\"flow-state\">{}</span><span class=\"flow-text\">{}</span>",
                html_escape(flow_state),
                html_escape(&flow_detail),
            );
            flow_banner.set_inner_html(&html);
            let _ = flow_banner.set_attribute("title", &next_action);
        }
        render_agent_round_flow(&document, &progress);

        let inferred_dm = if !progress.dm_keeper.trim().is_empty() {
            progress.dm_keeper.trim().to_string()
        } else {
            actors
                .iter()
                .find(|actor| actor.id == "dm" && !actor.keeper.trim().is_empty())
                .map(|actor| actor.keeper.trim().to_string())
                .unwrap_or_default()
        };
        if let Some(dm_input) = document
            .get_element_by_id("round-run-dm")
            .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        {
            if dm_input.value().trim().is_empty() && !inferred_dm.is_empty() {
                dm_input.set_value(&inferred_dm);
            }
        }

        let inferred_player_pairs = actors
            .iter()
            .filter(|actor| actor.id != "dm" && !actor.keeper.trim().is_empty())
            .map(|actor| format!("{}={}", actor.id.trim(), actor.keeper.trim()))
            .collect::<Vec<_>>();
        if let Some(players_input) = document
            .get_element_by_id("round-run-players")
            .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        {
            if players_input.value().trim().is_empty() && !inferred_player_pairs.is_empty() {
                players_input.set_value(&inferred_player_pairs.join(","));
            }
        }

        if let Some(summary) = document.get_element_by_id("round-run-summary") {
            if summary.text_content().unwrap_or_default().trim().is_empty()
                && !inferred_dm.is_empty()
                && !inferred_player_pairs.is_empty()
            {
                summary.set_text_content(Some(&format!(
                    "DM: {} · 플레이어: {}",
                    inferred_dm,
                    inferred_player_pairs.join(", ")
                )));
                let _ = summary.set_attribute("style", "display:block");
            }
        }
        persist_round_plan_inputs(&document, &room_id);

        if let Some(debug_el) = document.get_element_by_id("round-sync-debug-body") {
            let runner_preview = if runner_last_result.trim().is_empty() {
                "-".to_string()
            } else {
                let compact = runner_last_result.trim().replace('\n', " ");
                compact.chars().take(180).collect::<String>()
            };
            let phase_sync_class = if phase_mismatch {
                "sync-error"
            } else {
                "sync-ok"
            };
            let turn_sync_class = if turn_mismatch {
                "sync-error"
            } else {
                "sync-ok"
            };
            let html = format!(
                concat!(
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">게임 방</span><span class=\"round-sync-value\">{room_id}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">세션 상태</span><span class=\"round-sync-value {room_class}\">{lifecycle}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">턴 동기화</span><span class=\"round-sync-value {turn_sync_class}\">room {room_turn} / progress {progress_turn}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">페이즈 동기화</span><span class=\"round-sync-value {phase_sync_class}\">room {room_phase} / progress {progress_phase}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">마지막 이벤트</span><span class=\"round-sync-value\">{last_event}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">마지막 결과</span><span class=\"round-sync-value\">{last_result}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">자동 진행 상태</span><span class=\"round-sync-value\">{runner_state}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">자동 진행 응답</span><span class=\"round-sync-value\">{runner_preview}</span></div>"
                ),
                room_id = html_escape(&room_id),
                room_class = room_class,
                lifecycle = html_escape(lifecycle.label_ko()),
                turn_sync_class = turn_sync_class,
                room_turn = room_turn_for_sync,
                progress_turn = progress_turn_for_sync,
                phase_sync_class = phase_sync_class,
                room_phase = html_escape(&room_phase_for_sync),
                progress_phase = html_escape(&progress_phase_for_sync),
                last_event = html_escape(if progress.last_event.trim().is_empty() {
                    "-"
                } else {
                    progress.last_event.trim()
                }),
                last_result = html_escape(if progress.last_result.trim().is_empty() {
                    "-"
                } else {
                    progress.last_result.trim()
                }),
                runner_state = html_escape(&runner_state),
                runner_preview = html_escape(&runner_preview),
            );
            debug_el.set_inner_html(&html);
        }

        let lifecycle_class = format!("{} {}", room_class, lifecycle.css_class());
        let lifecycle_label =
            html_escape(&format!("{} ({})", lifecycle.label_ko(), lifecycle.label()));
        let html = format!(
            r#"
<div class="turn-runtime-grid">
  <div class="turn-runtime-item turn-runtime-item-wide"><span class="k">세션 상태</span><span class="v {lifecycle_class}">{lifecycle_label}</span></div>
  <div class="turn-runtime-item turn-runtime-item-wide"><span class="k">설명</span><span class="v">{lifecycle_help}</span></div>
  <div class="turn-runtime-item"><span class="k">상태</span><span class="v {room_class}">{room}</span></div>
  <div class="turn-runtime-item"><span class="k">턴</span><span class="v">{turn}</span></div>
  <div class="turn-runtime-item"><span class="k">페이즈</span><span class="v">{phase}</span></div>
  <div class="turn-runtime-item"><span class="k">입력</span><span class="v {input_class}">{input}</span></div>
  <div class="turn-runtime-item"><span class="k">현재</span><span class="v">{current} · {current_status}</span></div>
  <div class="turn-runtime-item"><span class="k">다음</span><span class="v">{next}</span></div>
  <div class="turn-runtime-item"><span class="k">직전</span><span class="v">{last}</span></div>
  <div class="turn-runtime-item turn-runtime-item-wide"><span class="k">이슈</span><span class="v {issues_class}">{issues}</span></div>
  <div class="turn-runtime-item turn-runtime-item-wide"><span class="k">다음 행동</span><span class="v">{next_action}</span></div>
  <div class="turn-runtime-item"><span class="k">파티</span><span class="v {party_class}">{party}</span></div>
</div>
"#,
            lifecycle_help = html_escape(lifecycle.help_text()),
            room_class = room_class,
            room = html_escape(room_status_label(lifecycle)),
            turn = turn,
            phase = html_escape(&pretty_phase(&phase)),
            input_class = input_class,
            input = html_escape(input_status),
            current = html_escape(&current_actor),
            current_status = html_escape(current_status),
            next = html_escape(&next_actor),
            last = html_escape(&last_result),
            issues_class = issues_class,
            issues = html_escape(&issues_summary),
            next_action = html_escape(&next_action),
            party_class = party_class,
            party = html_escape(&party_status),
        );
        el.set_inner_html(&html);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::game::state::TurnProgressState;

    #[test]
    fn summarize_actor_issues_respects_actor_order_and_reason() {
        let mut progress = TurnProgressState::default();
        progress.actor_order = vec!["dm".to_string(), "p01".to_string(), "p02".to_string()];
        progress
            .actor_states
            .insert("p02".to_string(), "unavailable".to_string());
        progress
            .actor_states
            .insert("p01".to_string(), "timeout".to_string());
        progress
            .actor_reasons
            .insert("p01".to_string(), "keeper heartbeat timeout".to_string());
        progress
            .actor_reasons
            .insert("p99".to_string(), "no keeper".to_string());

        let (summary, has_issues) = summarize_actor_issues(&progress);
        assert!(has_issues);
        assert_eq!(
            summary,
            "p01: timeout (keeper heartbeat timeout) · p02: unavailable · p99: issue (no keeper)"
        );
    }

    #[test]
    fn next_action_prefers_issue_recovery_when_running() {
        let hint = build_next_action_hint(TrpgLifecycleState::Running, false, "-", true);
        assert_eq!(hint, "keeper 상태를 확인한 뒤 라운드 실행을 다시 누르세요.");
    }

    #[test]
    fn next_action_waits_for_current_actor_when_running() {
        let hint = build_next_action_hint(TrpgLifecycleState::Running, false, "p03", false);
        assert_eq!(hint, "p03 응답을 기다리는 중입니다.");
    }

    #[test]
    fn flow_banner_prioritizes_connection_failure() {
        let (state, class_name, detail) = build_flow_banner(
            TrpgLifecycleState::Running,
            &ConnectionStatus::Failed,
            false,
            false,
            "-",
            "라운드 실행을 누르세요.",
        );
        assert_eq!(state, "연결 오류");
        assert_eq!(class_name, "is-error");
        assert!(detail.contains("연결"));
    }

    #[test]
    fn flow_banner_marks_auto_run_as_running() {
        let (state, class_name, detail) = build_flow_banner(
            TrpgLifecycleState::Running,
            &ConnectionStatus::Connected,
            true,
            false,
            "p01",
            "자동 진행 중입니다.",
        );
        assert_eq!(state, "자동 진행");
        assert_eq!(class_name, "is-running");
        assert!(detail.contains("자동"));
    }
}
