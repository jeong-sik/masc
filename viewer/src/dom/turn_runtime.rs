use bevy::prelude::*;
use std::collections::BTreeSet;

use crate::game::components::Actor;
use crate::game::lifecycle::TrpgLifecycleState;
use crate::game::round_runner::RoundRunner;
use crate::game::state::{ConnectionStatus, WorkspaceState, TurnProgressState};

/// Tracks last-rendered runtime status snapshot to avoid redundant DOM updates.
#[derive(Resource, Default)]
pub struct TurnRuntimeCache {
    pub last_snapshot: String,
    pub last_flow_action_snapshot: String,
}

#[cfg(target_arch = "wasm32")]
use super::escape::html_escape;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::closure::Closure;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;
#[cfg(target_arch = "wasm32")]
use web_sys::{HtmlElement, HtmlInputElement, HtmlSelectElement};

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
fn workspace_status_class(state: TrpgLifecycleState) -> &'static str {
    match state {
        TrpgLifecycleState::Running => "status-active",
        TrpgLifecycleState::Stopped => "status-paused",
        TrpgLifecycleState::Ended => "status-ended",
        TrpgLifecycleState::Unavailable => "status-unavailable",
        TrpgLifecycleState::Loading => "status-loading",
        TrpgLifecycleState::Idle | TrpgLifecycleState::Unknown => "status-idle",
    }
}

#[cfg(target_arch = "wasm32")]
fn workspace_status_label(state: TrpgLifecycleState) -> &'static str {
    state.label_ko()
}

#[cfg(target_arch = "wasm32")]
fn workspace_display_label(workspace_id: &str) -> String {
    if workspace_id.eq_ignore_ascii_case(crate::config::DEFAULT_WORKSPACE_ID) {
        format!("{} (기본 방)", crate::config::DEFAULT_WORKSPACE_ID)
    } else {
        workspace_id.to_string()
    }
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
    let normalized = phase.trim().to_ascii_lowercase().replace('-', "_");
    match normalized.as_str() {
        "briefing" | "dm" | "narration" | "dm_narration" => "dm_narration".to_string(),
        "discuss" | "discussion" | "player_discuss" | "party_discussion" | "action"
        | "player_action" | "dice" | "roll" | "dice_resolution" => "round".to_string(),
        _ => normalized,
    }
}

fn phase_is_aggregate_round(phase: &str) -> bool {
    normalize_phase_for_sync(phase) == "round"
}

fn phase_matches_for_sync(workspace_phase: &str, progress_phase: &str) -> bool {
    let workspace_norm = normalize_phase_for_sync(workspace_phase);
    let progress_norm = normalize_phase_for_sync(progress_phase);
    if workspace_norm == progress_norm {
        return true;
    }
    if workspace_norm.is_empty() || progress_norm.is_empty() {
        return false;
    }
    phase_is_aggregate_round(&workspace_norm) || phase_is_aggregate_round(&progress_norm)
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

#[derive(Default, Clone, Debug)]
struct RunnerSummaryDiagnostics {
    turn_before: Option<u64>,
    turn_after: Option<u64>,
    advanced: Option<bool>,
    progress_reason: Option<String>,
    recovery_mode: Option<String>,
    recovery_applied: bool,
    effective_timeout_sec: Option<f64>,
    roll_audit_count: Option<u64>,
}

fn parse_runner_summary_diagnostics(raw: &str) -> Option<RunnerSummaryDiagnostics> {
    let parsed = serde_json::from_str::<serde_json::Value>(raw).ok()?;
    let summary = parsed.get("summary")?;
    Some(RunnerSummaryDiagnostics {
        turn_before: parsed
            .get("turn_before")
            .and_then(serde_json::Value::as_u64),
        turn_after: parsed.get("turn_after").and_then(serde_json::Value::as_u64),
        advanced: summary.get("advanced").and_then(serde_json::Value::as_bool),
        progress_reason: summary
            .get("progress_reason")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| value.to_string()),
        recovery_mode: summary
            .get("recovery_mode")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| value.to_string()),
        recovery_applied: summary
            .get("recovery_applied")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false),
        effective_timeout_sec: summary
            .get("effective_timeout_sec")
            .and_then(serde_json::Value::as_f64),
        roll_audit_count: summary
            .get("roll_audit_count")
            .and_then(serde_json::Value::as_u64),
    })
}

fn compact_runner_diagnostics(diag: &RunnerSummaryDiagnostics) -> Option<String> {
    let mut parts = Vec::new();
    if let (Some(before), Some(after)) = (diag.turn_before, diag.turn_after) {
        parts.push(format!("turn {}→{}", before, after));
    }
    if let Some(reason) = diag.progress_reason.as_deref() {
        parts.push(reason.to_string());
    } else if let Some(advanced) = diag.advanced {
        parts.push(if advanced {
            "advanced".to_string()
        } else {
            "stalled".to_string()
        });
    }
    if let Some(mode) = diag.recovery_mode.as_deref() {
        parts.push(format!("mode {}", mode));
    }
    if diag.recovery_applied {
        parts.push("fallback".to_string());
    }
    if let Some(timeout_sec) = diag.effective_timeout_sec {
        parts.push(format!("{timeout_sec:.0}s"));
    }
    if let Some(audit_count) = diag.roll_audit_count {
        if audit_count > 0 {
            parts.push(format!("roll {}", audit_count));
        }
    }

    if parts.is_empty() {
        None
    } else {
        Some(parts.join(" · "))
    }
}

fn compact_runner_result(raw: &str) -> String {
    if let Some(diag) = parse_runner_summary_diagnostics(raw) {
        if let Some(compact) = compact_runner_diagnostics(&diag) {
            return compact_reason_text(&compact);
        }
    }

    let compact = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    const MAX_PREVIEW_CHARS: usize = 96;
    if compact.chars().count() <= MAX_PREVIEW_CHARS {
        compact
    } else {
        let mut short = compact.chars().take(MAX_PREVIEW_CHARS).collect::<String>();
        short.push_str("...");
        short
    }
}

fn runner_result_has_issue(raw: &str) -> bool {
    if raw.trim().is_empty() {
        return false;
    }

    let lowered = raw.to_ascii_lowercase();
    [
        "error",
        "failed",
        "timeout",
        "unavailable",
        "stall",
        "stuck",
        "invalid",
        "missing",
        "busy",
        "retry",
        "conflict",
        "lock",
        "429",
        "500",
        "503",
    ]
    .iter()
    .any(|keyword| lowered.contains(keyword))
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
        // P7: Clear thinking timer on completion.
        #[cfg(target_arch = "wasm32")]
        {
            if let Some(dash) = document.get_element_by_id("dashboard") {
                let _ = dash.remove_attribute("data-dm-thinking-start");
            }
        }
        format!("DM 처리 완료 ({})", dm_state)
    } else if dm_state == "thinking" {
        // P7: Show elapsed seconds during DM thinking via Performance.now().
        #[cfg(target_arch = "wasm32")]
        {
            let now_ms = web_sys::window()
                .and_then(|w| w.performance())
                .map(|p: web_sys::Performance| p.now())
                .unwrap_or(0.0);
            let start_ms = document
                .get_element_by_id("dashboard")
                .and_then(|dash| dash.get_attribute("data-dm-thinking-start"))
                .and_then(|v| v.parse::<f64>().ok())
                .unwrap_or_else(|| {
                    if let Some(dash) = document.get_element_by_id("dashboard") {
                        let _ = dash.set_attribute("data-dm-thinking-start", &now_ms.to_string());
                    }
                    now_ms
                });
            let elapsed_sec = (now_ms - start_ms) / 1000.0;
            format!("DM 응답 생성 중 ({:.1}s)", elapsed_sec)
        }
        #[cfg(not(target_arch = "wasm32"))]
        {
            "DM 응답 생성 중 (thinking)".to_string()
        }
    } else {
        // P7: Clear thinking timer when DM is not thinking.
        #[cfg(target_arch = "wasm32")]
        {
            if let Some(dash) = document.get_element_by_id("dashboard") {
                let _ = dash.remove_attribute("data-dm-thinking-start");
            }
        }
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
    has_runner_issue: bool,
) -> String {
    if runner_running && has_runner_issue {
        return "자동 진행 응답에 이슈가 있습니다. 멈춤 후 재개 또는 라운드 실행을 다시 누르세요."
            .to_string();
    }
    if !runner_running && has_runner_issue {
        return "직전 자동 진행에서 이슈가 있었습니다. 원인 확인 후 재개 또는 라운드 실행을 누르세요."
            .to_string();
    }
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
            TrpgLifecycleState::Idle => "세션을 시작한 뒤 라운드 실행을 누르세요.".to_string(),
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

struct FlowBannerInput<'a> {
    runner_running: bool,
    has_actor_issues: bool,
    has_runner_issue: bool,
    current_actor: &'a str,
    next_action: &'a str,
    runner_preview: &'a str,
}

fn build_flow_banner(
    lifecycle: TrpgLifecycleState,
    connection: &ConnectionStatus,
    input: FlowBannerInput<'_>,
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
            TrpgLifecycleState::Idle | TrpgLifecycleState::Unknown => (
                "대기",
                "is-idle",
                "새 게임을 시작하거나 실행 가능한 방으로 이동하세요.".to_string(),
            ),
            TrpgLifecycleState::Running => {
                if input.has_runner_issue {
                    let detail =
                        if input.runner_preview.trim().is_empty() || input.runner_preview == "-" {
                            format!("자동 진행 이슈 감지 · {}", input.next_action)
                        } else {
                            format!(
                                "자동 진행 이슈 감지 ({}) · {}",
                                input.runner_preview, input.next_action
                            )
                        };
                    ("주의", "is-alert", detail)
                } else if input.runner_running {
                    (
                        "자동 진행",
                        "is-running",
                        format!("AI 라운드 자동 순환 중 · {}", input.next_action),
                    )
                } else if input.has_actor_issues {
                    (
                        "주의",
                        "is-alert",
                        format!("응답 이슈 감지 · {}", input.next_action),
                    )
                } else if !input.current_actor.trim().is_empty()
                    && input.current_actor.trim() != "-"
                {
                    (
                        "진행 중",
                        "is-running",
                        format!(
                            "{} 턴 처리 중 · {}",
                            input.current_actor.trim(),
                            input.next_action
                        ),
                    )
                } else {
                    (
                        "대기",
                        "is-waiting",
                        format!("다음 액션 대기 · {}", input.next_action),
                    )
                }
            }
        },
    }
}

fn build_flow_action_signature(
    lifecycle: TrpgLifecycleState,
    runner_running: bool,
    has_actor_issues: bool,
    has_runner_issue: bool,
    current_actor: &str,
) -> String {
    let mut parts = Vec::new();
    if matches!(
        lifecycle,
        TrpgLifecycleState::Idle
            | TrpgLifecycleState::Loading
            | TrpgLifecycleState::Ended
            | TrpgLifecycleState::Unavailable
            | TrpgLifecycleState::Unknown
    ) {
        parts.push("new_game");
    }
    if runner_running {
        parts.push("auto");
    } else {
        parts.push("manual");
    }
    if has_actor_issues {
        parts.push("actor_issue");
    }
    if has_runner_issue {
        parts.push("runner_issue");
    }
    let actor = current_actor.trim();
    if actor.is_empty() || actor == "-" {
        parts.push("actor_idle");
    } else {
        parts.push("actor_active");
    }
    parts.join(",")
}

#[cfg(target_arch = "wasm32")]
#[derive(Clone)]
struct FlowBannerAction {
    key: &'static str,
    label: String,
    title: &'static str,
}

#[cfg(target_arch = "wasm32")]
fn flow_banner_action_snapshot(actions: &[FlowBannerAction]) -> String {
    actions
        .iter()
        .map(|action| format!("{}:{}", action.key, action.label))
        .collect::<Vec<_>>()
        .join("|")
}

#[cfg(target_arch = "wasm32")]
fn push_flow_action(actions: &mut Vec<FlowBannerAction>, action: FlowBannerAction) {
    if actions.iter().any(|existing| existing.key == action.key) {
        return;
    }
    actions.push(action);
}

#[cfg(target_arch = "wasm32")]
fn dom_element_visible(document: &web_sys::Document, id: &str) -> bool {
    let Some(el) = document.get_element_by_id(id) else {
        return false;
    };
    if el.has_attribute("hidden") {
        return false;
    }
    if let Some(style) = el.get_attribute("style") {
        let style = style.to_ascii_lowercase().replace(' ', "");
        if style.contains("display:none") || style.contains("visibility:hidden") {
            return false;
        }
    }
    true
}

#[cfg(target_arch = "wasm32")]
fn dom_element_disabled(document: &web_sys::Document, id: &str) -> bool {
    let Some(el) = document.get_element_by_id(id) else {
        return true;
    };
    if el.has_attribute("disabled") {
        return true;
    }
    el.get_attribute("aria-disabled")
        .map(|value| value.trim().eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

#[cfg(target_arch = "wasm32")]
fn auto_toggle_action_label(document: &web_sys::Document) -> String {
    let current = document
        .get_element_by_id("auto-round-toggle")
        .and_then(|el| el.text_content())
        .unwrap_or_default()
        .to_ascii_uppercase();
    if current.contains("OFF") {
        "자동 진행 켜기".to_string()
    } else {
        "자동 진행 끄기".to_string()
    }
}

#[cfg(target_arch = "wasm32")]
fn collect_flow_banner_actions(
    document: &web_sys::Document,
    lifecycle: TrpgLifecycleState,
    runner_running: bool,
    has_actor_issues: bool,
    has_runner_issue: bool,
    current_actor: &str,
) -> Vec<FlowBannerAction> {
    let mut actions = Vec::new();
    let turn_controls_visible = dom_element_visible(document, "turn-controls");
    let can_run_round =
        turn_controls_visible && !dom_element_disabled(document, "advance-turn-btn");
    let recovery_visible = dom_element_visible(document, "round-recovery-btn");
    let join_panel_visible = dom_element_visible(document, "join-panel");
    let action_panel_visible = dom_element_visible(document, "action-panel");

    if matches!(
        lifecycle,
        TrpgLifecycleState::Idle
            | TrpgLifecycleState::Loading
            | TrpgLifecycleState::Ended
            | TrpgLifecycleState::Unavailable
            | TrpgLifecycleState::Unknown
    ) {
        push_flow_action(
            &mut actions,
            FlowBannerAction {
                key: "open-new-game",
                label: "새 게임".to_string(),
                title: "새 게임 패널을 열어 세션과 파티를 다시 구성합니다.",
            },
        );
    }

    if can_run_round {
        push_flow_action(
            &mut actions,
            FlowBannerAction {
                key: "run-round",
                label: "라운드 실행".to_string(),
                title: "현재 상태로 라운드를 한 번 실행합니다.",
            },
        );
    }

    if document.get_element_by_id("auto-round-toggle").is_some() {
        push_flow_action(
            &mut actions,
            FlowBannerAction {
                key: "toggle-auto",
                label: auto_toggle_action_label(document),
                title: "자동 라운드 진행을 켜거나 끕니다.",
            },
        );
    }

    if recovery_visible
        && (has_actor_issues
            || has_runner_issue
            || matches!(
                lifecycle,
                TrpgLifecycleState::Stopped | TrpgLifecycleState::Unavailable
            ))
    {
        push_flow_action(
            &mut actions,
            FlowBannerAction {
                key: "open-recovery",
                label: "복구 가이드".to_string(),
                title: "라운드 복구 가이드를 열어 timeout/keeper 이슈를 점검합니다.",
            },
        );
    }

    if join_panel_visible {
        push_flow_action(
            &mut actions,
            FlowBannerAction {
                key: "focus-join",
                label: "참여 입력칸".to_string(),
                title: "플레이어 참여용 액터 ID 입력칸으로 이동합니다.",
            },
        );
    } else if action_panel_visible
        && (!runner_running
            || current_actor.trim().is_empty()
            || current_actor.trim() == "-"
            || lifecycle.accepts_player_input())
    {
        push_flow_action(
            &mut actions,
            FlowBannerAction {
                key: "focus-action",
                label: "행동 입력칸".to_string(),
                title: "플레이어 행동 입력칸으로 이동합니다.",
            },
        );
    }

    if actions.is_empty() && can_run_round {
        push_flow_action(
            &mut actions,
            FlowBannerAction {
                key: "run-round",
                label: "라운드 실행".to_string(),
                title: "현재 상태로 라운드를 한 번 실행합니다.",
            },
        );
    }

    if actions.len() > 4 {
        actions.truncate(4);
    }
    actions
}

#[cfg(target_arch = "wasm32")]
fn click_dom_button(document: &web_sys::Document, id: &str) {
    let Some(el) = document.get_element_by_id(id) else {
        return;
    };
    if el.has_attribute("disabled") {
        return;
    }
    if el
        .get_attribute("aria-disabled")
        .map(|value| value.trim().eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        return;
    }
    if let Ok(el) = el.dyn_into::<HtmlElement>() {
        el.click();
    }
}

#[cfg(target_arch = "wasm32")]
fn focus_dom_input(document: &web_sys::Document, id: &str) {
    let Some(input) = document
        .get_element_by_id(id)
        .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
    else {
        return;
    };
    let _ = input.focus();
}

#[cfg(target_arch = "wasm32")]
fn trigger_flow_banner_action(document: &web_sys::Document, action: &str) {
    match action.trim() {
        "open-new-game" => click_dom_button(document, "new-game-toggle"),
        "run-round" => click_dom_button(document, "advance-turn-btn"),
        "toggle-auto" => click_dom_button(document, "auto-round-toggle"),
        "open-recovery" => click_dom_button(document, "round-recovery-btn"),
        "focus-join" => focus_dom_input(document, "actor-id-input"),
        "focus-action" => focus_dom_input(document, "action-input"),
        _ => {}
    }
}

#[cfg(target_arch = "wasm32")]
fn ensure_flow_banner_action_binding(document: &web_sys::Document) {
    let Some(actions_el) = document.get_element_by_id("turn-flow-actions") else {
        return;
    };
    if actions_el
        .get_attribute("data-bound")
        .as_deref()
        .map(|value| value == "1")
        .unwrap_or(false)
    {
        return;
    }

    let cb = Closure::wrap(Box::new(move |evt: web_sys::Event| {
        let Some(target) = evt.target() else {
            return;
        };
        let Some(mut el) = target.dyn_into::<web_sys::Element>().ok() else {
            return;
        };

        let mut action = None;
        loop {
            if let Some(value) = el.get_attribute("data-flow-action") {
                action = Some(value);
                break;
            }
            let Some(parent) = el.parent_element() else {
                break;
            };
            el = parent;
        }
        let Some(action) = action else {
            return;
        };

        evt.prevent_default();
        if let Some(document) = web_sys::window().and_then(|window| window.document()) {
            trigger_flow_banner_action(&document, &action);
        }
    }) as Box<dyn FnMut(_)>);
    let _ = actions_el.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref());
    cb.forget();
    let _ = actions_el.set_attribute("data-bound", "1");
}

#[cfg(target_arch = "wasm32")]
fn render_flow_banner_actions(
    document: &web_sys::Document,
    cache: &mut TurnRuntimeCache,
    lifecycle: TrpgLifecycleState,
    runner_running: bool,
    has_actor_issues: bool,
    has_runner_issue: bool,
    current_actor: &str,
) {
    let Some(actions_el) = document.get_element_by_id("turn-flow-actions") else {
        return;
    };
    ensure_flow_banner_action_binding(document);

    let actions = collect_flow_banner_actions(
        document,
        lifecycle,
        runner_running,
        has_actor_issues,
        has_runner_issue,
        current_actor,
    );
    let snapshot = flow_banner_action_snapshot(&actions);
    if cache.last_flow_action_snapshot == snapshot {
        return;
    }
    cache.last_flow_action_snapshot = snapshot.clone();
    let _ = actions_el.set_attribute("data-snapshot", &snapshot);

    if actions.is_empty() {
        actions_el.set_inner_html("");
        return;
    }

    let html = actions
        .iter()
        .map(|action| {
            format!(
                "<button type=\"button\" class=\"flow-action-chip\" data-flow-action=\"{key}\" title=\"{title}\">{label}</button>",
                key = html_escape(action.key),
                title = html_escape(action.title),
                label = html_escape(&action.label),
            )
        })
        .collect::<Vec<_>>()
        .join("");
    actions_el.set_inner_html(&html);
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
fn runtime_compact_lifecycle(lifecycle: TrpgLifecycleState) -> bool {
    matches!(
        lifecycle,
        TrpgLifecycleState::Idle
            | TrpgLifecycleState::Loading
            | TrpgLifecycleState::Ended
            | TrpgLifecycleState::Unavailable
            | TrpgLifecycleState::Unknown
    )
}

#[cfg(target_arch = "wasm32")]
fn sync_runtime_advanced_toggle_ui(document: &web_sys::Document) {
    let Some(dashboard) = document.get_element_by_id("dashboard") else {
        return;
    };
    let show_advanced = dashboard
        .get_attribute("data-show-advanced")
        .map(|raw| {
            raw == "1"
                || raw.eq_ignore_ascii_case("true")
                || raw.eq_ignore_ascii_case("yes")
                || raw.eq_ignore_ascii_case("on")
        })
        .unwrap_or(true);
    let is_compact = dashboard
        .get_attribute("data-runtime-compact")
        .map(|raw| raw == "1")
        .unwrap_or(false);

    if let Some(toggle) = document.get_element_by_id("runtime-advanced-toggle") {
        toggle.set_text_content(Some(if show_advanced {
            "고급 정보 숨기기"
        } else {
            "고급 정보 보기"
        }));
        let _ = toggle.set_attribute("aria-pressed", if show_advanced { "true" } else { "false" });
        let _ = toggle.set_attribute(
            "class",
            if show_advanced {
                "inline-toggle runtime-advanced-toggle primary"
            } else {
                "inline-toggle runtime-advanced-toggle"
            },
        );
        let _ = toggle.set_attribute(
            "title",
            if show_advanced {
                "상태 전이/라운드 진단/DM 음성 설정을 숨깁니다."
            } else {
                "상태 전이/라운드 진단/DM 음성 설정을 펼칩니다."
            },
        );
    }
    if let Some(hint) = document.get_element_by_id("runtime-advanced-hint") {
        let text = if show_advanced {
            "상태 전이, 라운드 진단, DM 음성 설정"
        } else if is_compact {
            "기본 정보만 표시 중 (대기/종료 단순 모드)"
        } else {
            "핵심 정보만 표시 중"
        };
        hint.set_text_content(Some(text));
    }
}

#[cfg(target_arch = "wasm32")]
fn ensure_runtime_advanced_toggle_binding(document: &web_sys::Document) {
    let Some(toggle) = document.get_element_by_id("runtime-advanced-toggle") else {
        return;
    };
    if toggle.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let cb = Closure::wrap(Box::new(move |evt: web_sys::Event| {
        evt.prevent_default();
        let Some(document) = web_sys::window().and_then(|window| window.document()) else {
            return;
        };
        let Some(dashboard) = document.get_element_by_id("dashboard") else {
            return;
        };
        let show_advanced = dashboard
            .get_attribute("data-show-advanced")
            .map(|raw| raw == "1")
            .unwrap_or(false);
        let _ =
            dashboard.set_attribute("data-show-advanced", if show_advanced { "0" } else { "1" });
        sync_runtime_advanced_toggle_ui(&document);
    }) as Box<dyn FnMut(_)>);
    let _ = toggle.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref());
    cb.forget();
    let _ = toggle.set_attribute("data-bound", "1");
}

#[cfg(target_arch = "wasm32")]
fn sync_runtime_panel_flags(document: &web_sys::Document, lifecycle: TrpgLifecycleState) {
    let Some(dashboard) = document.get_element_by_id("dashboard") else {
        return;
    };
    let was_compact = dashboard
        .get_attribute("data-runtime-compact")
        .map(|raw| raw == "1")
        .unwrap_or(false);
    let is_compact = runtime_compact_lifecycle(lifecycle);
    let _ = dashboard.set_attribute("data-runtime-compact", if is_compact { "1" } else { "0" });

    if is_compact && !was_compact {
        let _ = dashboard.set_attribute("data-show-advanced", "0");
    } else if dashboard.get_attribute("data-show-advanced").is_none() {
        let _ = dashboard.set_attribute("data-show-advanced", if is_compact { "0" } else { "1" });
    }

    ensure_runtime_advanced_toggle_binding(document);
    sync_runtime_advanced_toggle_ui(document);
}

#[cfg(target_arch = "wasm32")]
fn round_plan_storage_key(workspace_id: &str) -> String {
    format!("masc.viewer.round_plan.{}", workspace_id.trim())
}

#[cfg(target_arch = "wasm32")]
fn restore_round_plan_inputs(document: &web_sys::Document, workspace_id: &str) {
    let Some(storage) = web_sys::window()
        .and_then(|w| w.local_storage().ok())
        .flatten()
    else {
        return;
    };
    let Ok(Some(raw)) = storage.get_item(&round_plan_storage_key(workspace_id)) else {
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
fn persist_round_plan_inputs(document: &web_sys::Document, workspace_id: &str) {
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

    let existing = storage
        .get_item(&round_plan_storage_key(workspace_id))
        .ok()
        .flatten()
        .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok());
    let existing_dm = existing
        .as_ref()
        .and_then(|payload| payload.get("dm"))
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .unwrap_or("");
    let existing_players = existing
        .as_ref()
        .and_then(|payload| payload.get("players"))
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .unwrap_or("");

    let dm_to_store = if dm.trim().is_empty() {
        existing_dm
    } else {
        dm.trim()
    };
    let players_to_store = if players.trim().is_empty() {
        existing_players
    } else {
        players.trim()
    };

    if dm_to_store.is_empty() && players_to_store.is_empty() {
        return;
    }

    let payload = serde_json::json!({
        "dm": dm_to_store,
        "players": players_to_store,
    });
    let _ = storage.set_item(&round_plan_storage_key(workspace_id), &payload.to_string());
}

/// Render live TRPG runtime progress:
/// workspace/turn/phase, current thinker, next actor, last outcome, and party survival.
pub fn update_turn_runtime_dom(
    workspace_state: Res<WorkspaceState>,
    progress: Res<TurnProgressState>,
    connection: Res<ConnectionStatus>,
    runner: Option<Res<RoundRunner>>,
    actors: Query<&Actor>,
    mut cache: ResMut<TurnRuntimeCache>,
) {
    let workspace_status_raw = if !progress.workspace_status.trim().is_empty() {
        progress.workspace_status.trim().to_string()
    } else if !workspace_state.status.trim().is_empty() {
        workspace_state.status.trim().to_string()
    } else {
        "unknown".to_string()
    };
    let lifecycle =
        TrpgLifecycleState::from_workspace_progress(&workspace_state.status, &progress.workspace_status);
    let workspace_status_key = crate::game::lifecycle::normalize_status(&workspace_status_raw);
    let turn = if progress.turn > 0 {
        progress.turn
    } else if workspace_state.turn > 0 {
        workspace_state.turn
    } else {
        1
    };
    let phase = if !progress.phase.trim().is_empty() {
        progress.phase.trim().to_string()
    } else {
        workspace_state.phase.as_str().to_string()
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

    let workspace_turn_for_sync = if workspace_state.turn > 0 {
        workspace_state.turn
    } else {
        turn
    };
    let workspace_phase_for_sync = workspace_state.phase.as_str().to_string();
    let progress_turn_for_sync = if progress.turn > 0 {
        progress.turn
    } else {
        turn
    };
    let progress_phase_for_sync = if progress.phase.trim().is_empty() {
        workspace_phase_for_sync.clone()
    } else {
        progress.phase.trim().to_string()
    };
    let turn_mismatch = workspace_turn_for_sync != progress_turn_for_sync;
    let phase_mismatch = !phase_matches_for_sync(&workspace_phase_for_sync, &progress_phase_for_sync);

    let (sync_state, sync_class) = if turn_mismatch || phase_mismatch {
        let mut reasons = Vec::new();
        if turn_mismatch {
            reasons.push(format!(
                "turn {}≠{}",
                workspace_turn_for_sync, progress_turn_for_sync
            ));
        }
        if phase_mismatch {
            reasons.push(format!(
                "phase {}≠{}",
                workspace_phase_for_sync, progress_phase_for_sync
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

    let runner_preview = if runner_last_result.trim().is_empty() {
        "-".to_string()
    } else {
        compact_runner_result(&runner_last_result)
    };
    let runner_diag = parse_runner_summary_diagnostics(&runner_last_result);
    let runner_diag_preview = runner_diag
        .as_ref()
        .and_then(compact_runner_diagnostics)
        .unwrap_or_else(|| "-".to_string());
    let has_runner_issue = runner_result_has_issue(&runner_last_result);
    let runner_state = if runner_running {
        if has_runner_issue {
            format!("자동 진행 {} 라운드 · 이슈 감지", runner_rounds)
        } else {
            format!("자동 진행 {} 라운드", runner_rounds)
        }
    } else if has_runner_issue {
        "대기 · 이전 실행 이슈".to_string()
    } else {
        "대기".to_string()
    };
    let next_action = build_next_action_hint(
        lifecycle,
        runner_running,
        &current_actor,
        has_actor_issues,
        has_runner_issue,
    );
    let (flow_state, flow_class, flow_detail) = build_flow_banner(
        lifecycle,
        &connection,
        FlowBannerInput {
            runner_running,
            has_actor_issues,
            has_runner_issue,
            current_actor: &current_actor,
            next_action: &next_action,
            runner_preview: &runner_preview,
        },
    );
    let flow_action_signature = build_flow_action_signature(
        lifecycle,
        runner_running,
        has_actor_issues,
        has_runner_issue,
        &current_actor,
    );

    let connection_label = connection_status_label(&connection);
    let connection_class = connection_status_class(&connection);

    #[cfg(not(target_arch = "wasm32"))]
    let _ = (
        &sync_class,
        &control_state,
        &runner_last_result,
        &runner_preview,
        &runner_diag_preview,
        &has_runner_issue,
        &flow_state,
        &flow_class,
        &flow_detail,
        &flow_action_signature,
        &cache.last_flow_action_snapshot,
    );

    let snapshot = vec![
        workspace_status_key.clone(),
        turn.to_string(),
        phase.clone(),
        current_actor.clone(),
        next_actor.clone(),
        last_result.clone(),
        party_status.clone(),
        current_status.to_string(),
        input_status.to_string(),
        connection_label.to_string(),
        connection_class.to_string(),
        sync_state.clone(),
        runner_state.clone(),
        runner_preview.clone(),
        runner_diag_preview.clone(),
        progress.last_event.clone(),
        issues_summary.clone(),
        next_action.clone(),
        flow_state.to_string(),
        flow_class.to_string(),
        flow_detail.clone(),
        flow_action_signature,
    ]
    .join("|");
    if cache.last_snapshot == snapshot {
        #[cfg(target_arch = "wasm32")]
        if let Some(document) = web_sys::window().and_then(|w| w.document()) {
            render_flow_banner_actions(
                &document,
                &mut cache,
                lifecycle,
                runner_running,
                has_actor_issues,
                has_runner_issue,
                &current_actor,
            );
        }
        return;
    }
    cache.last_snapshot = snapshot;

    #[cfg(target_arch = "wasm32")]
    {
        let Some(document) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        sync_runtime_panel_flags(&document, lifecycle);
        let Some(el) = document.get_element_by_id("turn-runtime") else {
            return;
        };

        let workspace_class = workspace_status_class(lifecycle);
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
        let runner_state_class = if has_runner_issue {
            "status-error"
        } else if runner_running {
            "status-active"
        } else {
            "status-idle"
        };
        let runner_preview_class = if has_runner_issue {
            "status-error"
        } else {
            "status-idle"
        };
        let input_class = if lifecycle.accepts_player_input() {
            "status-active"
        } else {
            workspace_class
        };

        let workspace_id = crate::config::sanitize_workspace_id(workspace_state.id.trim())
            .unwrap_or_else(crate::config::current_workspace_id);
        if let Some(dashboard) = document.get_element_by_id("dashboard") {
            let _ = dashboard.set_attribute("data-workspace-id", &workspace_id);
        }

        if let Some(workspace_status_el) = document.get_element_by_id("workspace-status") {
            let workspace_label = workspace_display_label(&workspace_id);
            workspace_status_el.set_text_content(Some(&format!(
                "현재 게임 {} · {}",
                workspace_label,
                lifecycle.label_ko()
            )));
            let _ = workspace_status_el.set_attribute("data-lifecycle", lifecycle.css_class());
            let _ = workspace_status_el.set_attribute(
                "title",
                &format!(
                    "{} | 턴 {} | 페이즈 {} | raw {}",
                    lifecycle.help_text(),
                    turn,
                    phase,
                    workspace_status_key
                ),
            );
        }

        let mut workspace_switched = false;
        if let Some(dashboard) = document.get_element_by_id("dashboard") {
            let previous_workspace = dashboard
                .get_attribute("data-round-plan-workspace")
                .unwrap_or_default();
            if previous_workspace.trim() != workspace_id {
                workspace_switched = true;
                let _ = dashboard.set_attribute("data-round-plan-workspace", &workspace_id);
            }
        }

        if workspace_switched {
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
            if let Some(claimed_workspace) = document
                .get_element_by_id("claimed-workspace-id")
                .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
            {
                claimed_workspace.set_value("");
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
            restore_round_plan_inputs(&document, &workspace_id);
        }

        set_ops_hud_value(&document, "ops-workspace-id", &workspace_id, workspace_class);
        set_ops_hud_value(
            &document,
            "ops-session-state",
            lifecycle.label_ko(),
            workspace_class,
        );
        set_ops_hud_value(
            &document,
            "ops-round-phase",
            &format!("T{} / {}", turn, pretty_phase(&phase)),
            workspace_class,
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
                workspace_class
            },
        );
        set_ops_hud_value(&document, "ops-sync-state", &sync_state, sync_class);
        if let Some(flow_banner) = document.get_element_by_id("turn-flow-banner") {
            let _ = flow_banner.set_attribute("class", &format!("turn-flow-banner {}", flow_class));
            let _ = flow_banner.set_attribute("title", &next_action);
        }
        if let Some(flow_state_el) = document.get_element_by_id("turn-flow-state") {
            flow_state_el.set_text_content(Some(flow_state));
        }
        if let Some(flow_text_el) = document.get_element_by_id("turn-flow-text") {
            flow_text_el.set_text_content(Some(&flow_detail));
        }
        render_flow_banner_actions(
            &document,
            &mut cache,
            lifecycle,
            runner_running,
            has_actor_issues,
            has_runner_issue,
            &current_actor,
        );
        render_agent_round_flow(&document, &progress);

        let inferred_dm = if !progress.dm_keeper.trim().is_empty() {
            progress.dm_keeper.trim().to_string()
        } else {
            actors
                .iter()
                .find(|actor| actor.id == "dm" && !actor.keeper.trim().is_empty())
                .map(|actor| actor.keeper.trim().to_string())
                .or_else(|| {
                    document
                        .get_element_by_id("new-game-dm-select")
                        .and_then(|el| el.dyn_into::<HtmlSelectElement>().ok())
                        .map(|select| select.value().trim().to_string())
                        .filter(|value| !value.is_empty())
                })
                .unwrap_or_default()
        };
        if let Some(dm_pill) = document.get_element_by_id("dm-keeper-pill") {
            if inferred_dm.is_empty() {
                dm_pill.set_text_content(Some("DM: 미지정"));
                let _ = dm_pill.set_attribute("class", "widget-pill status-warn");
                let _ = dm_pill.set_attribute("title", "현재 DM keeper가 지정되지 않았습니다.");
            } else {
                dm_pill.set_text_content(Some(&format!("DM: {}", inferred_dm)));
                let _ = dm_pill.set_attribute("class", "widget-pill status-ok");
                let _ = dm_pill.set_attribute("title", "현재 DM keeper");
            }
        }
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
        persist_round_plan_inputs(&document, &workspace_id);

        if let Some(debug_el) = document.get_element_by_id("round-sync-debug-body") {
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
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">게임 방</span><span class=\"round-sync-value\">{workspace_id}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">세션 상태</span><span class=\"round-sync-value {workspace_class}\">{lifecycle}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">턴 동기화</span><span class=\"round-sync-value {turn_sync_class}\">workspace {workspace_turn} / progress {progress_turn}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">페이즈 동기화</span><span class=\"round-sync-value {phase_sync_class}\">workspace {workspace_phase} / progress {progress_phase}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">마지막 이벤트</span><span class=\"round-sync-value\">{last_event}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">마지막 결과</span><span class=\"round-sync-value\">{last_result}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">자동 진행 상태</span><span class=\"round-sync-value\">{runner_state}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">자동 진행 응답</span><span class=\"round-sync-value\">{runner_preview}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">라운드 진단</span><span class=\"round-sync-value\">{runner_diag_preview}</span></div>"
                ),
                workspace_id = html_escape(&workspace_id),
                workspace_class = workspace_class,
                lifecycle = html_escape(lifecycle.label_ko()),
                turn_sync_class = turn_sync_class,
                workspace_turn = workspace_turn_for_sync,
                progress_turn = progress_turn_for_sync,
                phase_sync_class = phase_sync_class,
                workspace_phase = html_escape(&workspace_phase_for_sync),
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
                runner_diag_preview = html_escape(&runner_diag_preview),
            );
            debug_el.set_inner_html(&html);
        }

        let lifecycle_class = format!("{} {}", workspace_class, lifecycle.css_class());
        let lifecycle_label =
            html_escape(&format!("{} ({})", lifecycle.label_ko(), lifecycle.label()));
        let html = format!(
            r#"
<div class="turn-runtime-grid">
  <div class="turn-runtime-item turn-runtime-item-wide"><span class="k">세션 상태</span><span class="v {lifecycle_class}">{lifecycle_label}</span></div>
  <div class="turn-runtime-item turn-runtime-item-wide"><span class="k">설명</span><span class="v">{lifecycle_help}</span></div>
  <div class="turn-runtime-item runtime-detail"><span class="k">상태</span><span class="v {workspace_class}">{workspace}</span></div>
  <div class="turn-runtime-item"><span class="k">턴</span><span class="v">{turn}</span></div>
  <div class="turn-runtime-item"><span class="k">페이즈</span><span class="v">{phase}</span></div>
  <div class="turn-runtime-item runtime-detail"><span class="k">입력</span><span class="v {input_class}">{input}</span></div>
  <div class="turn-runtime-item runtime-detail"><span class="k">현재</span><span class="v">{current} · {current_status}</span></div>
  <div class="turn-runtime-item runtime-detail"><span class="k">다음</span><span class="v">{next}</span></div>
  <div class="turn-runtime-item runtime-detail"><span class="k">직전</span><span class="v">{last}</span></div>
  <div class="turn-runtime-item"><span class="k">자동 진행</span><span class="v {runner_state_class}">{runner_state}</span></div>
  <div class="turn-runtime-item turn-runtime-item-wide"><span class="k">이슈</span><span class="v {issues_class}">{issues}</span></div>
  <div class="turn-runtime-item turn-runtime-item-wide runtime-detail"><span class="k">자동 진행 응답</span><span class="v {runner_preview_class}">{runner_preview}</span></div>
  <div class="turn-runtime-item turn-runtime-item-wide"><span class="k">다음 행동</span><span class="v">{next_action}</span></div>
  <div class="turn-runtime-item runtime-detail"><span class="k">파티</span><span class="v {party_class}">{party}</span></div>
</div>
"#,
            lifecycle_help = html_escape(lifecycle.help_text()),
            workspace_class = workspace_class,
            workspace = html_escape(workspace_status_label(lifecycle)),
            turn = turn,
            phase = html_escape(&pretty_phase(&phase)),
            input_class = input_class,
            input = html_escape(input_status),
            current = html_escape(&current_actor),
            current_status = html_escape(current_status),
            next = html_escape(&next_actor),
            last = html_escape(&last_result),
            runner_state_class = runner_state_class,
            runner_state = html_escape(&runner_state),
            issues_class = issues_class,
            issues = html_escape(&issues_summary),
            runner_preview_class = runner_preview_class,
            runner_preview = html_escape(&runner_preview),
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
        let mut progress = TurnProgressState {
            actor_order: vec!["dm".to_string(), "p01".to_string(), "p02".to_string()],
            ..TurnProgressState::default()
        };
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
        let hint = build_next_action_hint(TrpgLifecycleState::Running, false, "-", true, false);
        assert_eq!(hint, "keeper 상태를 확인한 뒤 라운드 실행을 다시 누르세요.");
    }

    #[test]
    fn next_action_waits_for_current_actor_when_running() {
        let hint = build_next_action_hint(TrpgLifecycleState::Running, false, "p03", false, false);
        assert_eq!(hint, "p03 응답을 기다리는 중입니다.");
    }

    #[test]
    fn next_action_warns_on_runner_issue() {
        let hint = build_next_action_hint(TrpgLifecycleState::Running, true, "-", false, true);
        assert!(hint.contains("자동 진행 응답"));
    }

    #[test]
    fn flow_banner_prioritizes_connection_failure() {
        let (state, class_name, detail) = build_flow_banner(
            TrpgLifecycleState::Running,
            &ConnectionStatus::Failed,
            FlowBannerInput {
                runner_running: false,
                has_actor_issues: false,
                has_runner_issue: false,
                current_actor: "-",
                next_action: "라운드 실행을 누르세요.",
                runner_preview: "-",
            },
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
            FlowBannerInput {
                runner_running: true,
                has_actor_issues: false,
                has_runner_issue: false,
                current_actor: "p01",
                next_action: "자동 진행 중입니다.",
                runner_preview: "-",
            },
        );
        assert_eq!(state, "자동 진행");
        assert_eq!(class_name, "is-running");
        assert!(detail.contains("자동"));
    }

    #[test]
    fn flow_banner_prioritizes_runner_issue() {
        let (state, class_name, detail) = build_flow_banner(
            TrpgLifecycleState::Running,
            &ConnectionStatus::Connected,
            FlowBannerInput {
                runner_running: true,
                has_actor_issues: false,
                has_runner_issue: true,
                current_actor: "p01",
                next_action: "자동 진행 응답에 이슈가 있습니다.",
                runner_preview: "keeper busy detected",
            },
        );
        assert_eq!(state, "주의");
        assert_eq!(class_name, "is-alert");
        assert!(detail.contains("이슈"));
    }

    #[test]
    fn runner_issue_detector_flags_common_errors() {
        assert!(runner_result_has_issue(
            "RoundRunner: round still stalled after 3 retries"
        ));
        assert!(runner_result_has_issue("HTTP 503 from engine"));
        assert!(!runner_result_has_issue("round completed successfully"));
    }

    #[test]
    fn parse_runner_summary_diagnostics_reads_round_summary_fields() {
        let payload = r#"{
            "ok": true,
            "turn_before": 12,
            "turn_after": 12,
            "summary": {
                "advanced": false,
                "progress_reason": "player_quorum_not_met",
                "recovery_mode": "local_fallback_applied",
                "recovery_applied": true,
                "effective_timeout_sec": 12,
                "roll_audit_count": 3
            }
        }"#;
        let diag = parse_runner_summary_diagnostics(payload).expect("summary diagnostics");
        assert_eq!(diag.turn_before, Some(12));
        assert_eq!(diag.turn_after, Some(12));
        assert_eq!(diag.advanced, Some(false));
        assert_eq!(
            diag.progress_reason.as_deref(),
            Some("player_quorum_not_met")
        );
        assert_eq!(
            diag.recovery_mode.as_deref(),
            Some("local_fallback_applied")
        );
        assert!(diag.recovery_applied);
        assert_eq!(diag.roll_audit_count, Some(3));
    }

    #[test]
    fn compact_runner_result_prefers_structured_diagnostics_when_available() {
        let payload = r#"{
            "turn_before": 7,
            "turn_after": 8,
            "summary": {
                "advanced": true,
                "progress_reason": "advanced",
                "effective_timeout_sec": 45
            }
        }"#;
        let compact = compact_runner_result(payload);
        assert!(compact.contains("turn 7→8"));
        assert!(compact.contains("advanced"));
    }
}
