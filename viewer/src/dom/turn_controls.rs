//! Turn Controls — execute one TRPG round and show round-run status.
//!
//! Binds DOM event listeners on `#turn-controls`:
//! - Run Round button → POST `/api/v1/trpg/rounds/run`
//!
//! Visible when a round run assignment is present:
//! - claimed keeper/actor for local manual play, or
//! - hidden round-run plan fields for AI auto-run flow.
//!   Follows the same OnEnter/OnExit lifecycle as `action_panel.rs`.

use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use serde_json::{json, Value};

#[cfg(target_arch = "wasm32")]
use web_sys::{Element, HtmlButtonElement, HtmlInputElement, HtmlSelectElement};

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use crate::config;
#[cfg(any(target_arch = "wasm32", test))]
use crate::game::lifecycle::{TrpgLifecycleState, TrpgUiState};
use crate::game::state::{ConnectionStatus, RoomState, TurnProgressState};

#[cfg(any(target_arch = "wasm32", test))]
fn connection_ready(status: &ConnectionStatus) -> bool {
    matches!(status, ConnectionStatus::Connected)
}

#[cfg(any(target_arch = "wasm32", test))]
fn derive_round_control_state(
    lifecycle: TrpgLifecycleState,
    connection_ok: bool,
    plan_error: Option<&str>,
) -> (bool, String, &'static str) {
    if !lifecycle.allows_round_control() {
        return (
            false,
            format!("실행 대기: {}", lifecycle.help_text()),
            "status-info",
        );
    }
    if !connection_ok {
        return (
            false,
            "실행 대기: 엔진 연결이 완료될 때까지 기다려주세요.".to_string(),
            "status-info",
        );
    }
    if let Some(err) = plan_error {
        return (false, format!("준비 필요: {}", err), "status-warn");
    }
    (true, "라운드 실행 가능".to_string(), "status-ok")
}

#[cfg(target_arch = "wasm32")]
fn control_status_to_ops_class(css_class: &str) -> &'static str {
    match css_class {
        "status-ok" => "status-active",
        "status-warn" => "status-warn",
        "status-error" => "status-error",
        _ => "status-idle",
    }
}

#[cfg(target_arch = "wasm32")]
fn set_round_readiness_rows(doc: &web_sys::Document, rows: &[RoundReadinessRow]) {
    let Some(container) = doc.get_element_by_id("round-readiness-checklist") else {
        return;
    };

    let snapshot = rows
        .iter()
        .map(|row| {
            format!(
                "{}:{}:{}",
                row.label,
                if row.ok { "1" } else { "0" },
                row.detail
            )
        })
        .collect::<Vec<_>>()
        .join("|");
    if container.get_attribute("data-snapshot").as_deref() == Some(snapshot.as_str()) {
        return;
    }
    let _ = container.set_attribute("data-snapshot", &snapshot);

    container.set_text_content(None);
    for row in rows {
        let Ok(item) = doc.create_element("div") else {
            continue;
        };
        item.set_class_name(if row.ok {
            "round-readiness-item is-ok"
        } else {
            "round-readiness-item is-fail"
        });

        let Ok(state) = doc.create_element("span") else {
            continue;
        };
        state.set_class_name("round-readiness-state");
        state.set_text_content(Some(if row.ok { "OK" } else { "WAIT" }));
        let _ = item.append_child(&state);

        let Ok(label) = doc.create_element("span") else {
            continue;
        };
        label.set_class_name("round-readiness-label");
        label.set_text_content(Some(row.label));
        let _ = item.append_child(&label);

        let Ok(detail) = doc.create_element("span") else {
            continue;
        };
        detail.set_class_name("round-readiness-detail");
        detail.set_text_content(Some(&row.detail));
        let _ = item.append_child(&detail);

        let _ = container.append_child(&item);
    }
}

#[cfg(any(target_arch = "wasm32", test))]
fn round_advanced(turn_before: u64, turn_after: u64, summary_advanced: Option<bool>) -> bool {
    summary_advanced.unwrap_or(turn_after > turn_before)
}

#[cfg(target_arch = "wasm32")]
#[derive(Clone, Debug)]
struct RoundStallSummary {
    successes: u64,
    player_successes: u64,
    dm_success: bool,
    timeouts: u64,
    unavailable: u64,
    first_issue: Option<String>,
}

#[cfg(any(target_arch = "wasm32", test))]
#[derive(Clone, Debug, PartialEq, Eq)]
struct RoundReadinessRow {
    label: &'static str,
    ok: bool,
    detail: String,
}

#[cfg(any(target_arch = "wasm32", test))]
fn derive_round_readiness_rows(
    connection_ok: bool,
    lifecycle: TrpgLifecycleState,
    dm_ready: bool,
    player_count: usize,
    lock_reason: Option<&str>,
) -> Vec<RoundReadinessRow> {
    vec![
        RoundReadinessRow {
            label: "엔진 연결",
            ok: connection_ok,
            detail: if connection_ok {
                "connected".to_string()
            } else {
                "연결 필요".to_string()
            },
        },
        RoundReadinessRow {
            label: "세션 상태",
            ok: lifecycle.allows_round_control(),
            detail: lifecycle.label_ko().to_string(),
        },
        RoundReadinessRow {
            label: "DM 배정",
            ok: dm_ready,
            detail: if dm_ready {
                "DM keeper 준비됨".to_string()
            } else {
                "DM keeper 없음".to_string()
            },
        },
        RoundReadinessRow {
            label: "플레이어 배정",
            ok: player_count > 0,
            detail: if player_count > 0 {
                format!("{}명 keeper 매핑", player_count)
            } else {
                "player keeper 없음".to_string()
            },
        },
        RoundReadinessRow {
            label: "실행 락",
            ok: lock_reason.is_none(),
            detail: lock_reason.unwrap_or("락 없음").to_string(),
        },
    ]
}

#[cfg(any(target_arch = "wasm32", test))]
fn derive_trpg_ui_state(
    lifecycle: TrpgLifecycleState,
    connection_ok: bool,
    wizard_busy: bool,
    preflight_ok: bool,
    wizard_ready: bool,
    round_running: bool,
) -> TrpgUiState {
    if !connection_ok || matches!(lifecycle, TrpgLifecycleState::Unavailable) {
        return TrpgUiState::Error;
    }
    if round_running {
        return TrpgUiState::RoundRunning;
    }
    if wizard_busy || matches!(lifecycle, TrpgLifecycleState::Loading) {
        return TrpgUiState::SessionStarting;
    }
    match lifecycle {
        TrpgLifecycleState::Running => TrpgUiState::SessionRunning,
        TrpgLifecycleState::Stopped => TrpgUiState::Paused,
        TrpgLifecycleState::Ended => TrpgUiState::Ended,
        TrpgLifecycleState::Lobby | TrpgLifecycleState::Unknown => {
            if preflight_ok && wizard_ready {
                TrpgUiState::ConfigReady
            } else {
                TrpgUiState::Lobby
            }
        }
        TrpgLifecycleState::Loading => TrpgUiState::SessionStarting,
        TrpgLifecycleState::Unavailable => TrpgUiState::Error,
    }
}

#[cfg(target_arch = "wasm32")]
fn read_new_game_wizard_busy(doc: &web_sys::Document) -> bool {
    doc.get_element_by_id("new-game-panel")
        .and_then(|panel| panel.get_attribute("data-wizard-busy"))
        .is_some_and(|flag| flag == "1")
}

#[cfg(target_arch = "wasm32")]
fn read_new_game_preflight_ok(doc: &web_sys::Document) -> bool {
    doc.get_element_by_id("new-game-panel")
        .and_then(|panel| panel.get_attribute("data-preflight-state"))
        .is_some_and(|state| state == "ok")
}

#[cfg(target_arch = "wasm32")]
fn read_new_game_assignment_ready(doc: &web_sys::Document) -> bool {
    let dm = doc
        .get_element_by_id("new-game-dm-select")
        .and_then(|el| el.dyn_into::<HtmlSelectElement>().ok())
        .map(|select| select.value().trim().to_string())
        .unwrap_or_default();
    if dm.is_empty() {
        return false;
    }

    let Ok(nodes) = doc.query_selector_all("#new-game-player-select option:checked") else {
        return false;
    };
    let mut selected_count = 0_u32;
    let mut has_conflict = false;
    for idx in 0..nodes.length() {
        let Some(node) = nodes.item(idx) else {
            continue;
        };
        let Some(option) = node.dyn_ref::<web_sys::HtmlOptionElement>() else {
            continue;
        };
        let value = option.value().trim().to_string();
        if value.is_empty() {
            continue;
        }
        if value == dm {
            has_conflict = true;
            continue;
        }
        selected_count += 1;
    }
    selected_count > 0 && !has_conflict
}

#[cfg(target_arch = "wasm32")]
fn summarize_ops_detail(detail: &str, max_chars: usize) -> String {
    let compact = detail.trim().replace('\n', " ");
    if compact.chars().count() <= max_chars {
        return compact;
    }
    let mut shortened = compact
        .chars()
        .take(max_chars.saturating_sub(1))
        .collect::<String>();
    shortened.push('…');
    shortened
}

#[cfg(target_arch = "wasm32")]
fn sync_dashboard_ui_state(doc: &web_sys::Document, state: TrpgUiState, detail: &str) {
    if let Some(dashboard) = doc.get_element_by_id("dashboard") {
        let _ = dashboard.set_attribute("data-trpg-ui-state", state.code());
        let _ = dashboard.set_attribute("data-trpg-ui-label", state.label_ko());
        let _ = dashboard.set_attribute("data-trpg-ui-help", state.help_text());
    }

    if let Some(el) = doc.get_element_by_id("ops-control-state") {
        let summary = summarize_ops_detail(detail, 96);
        let text = if summary.is_empty() {
            state.label_ko().to_string()
        } else {
            format!("{} · {}", state.label_ko(), summary)
        };
        let class_name = format!("ops-v {}", state.ops_class());
        el.set_text_content(Some(&text));
        let _ = el.set_attribute("class", &class_name);
        let _ = el.set_attribute(
            "title",
            &format!("{} | {}", state.help_text(), detail.trim()),
        );
    }
}
// ─── Marker Resource ────────────────────────

/// Inserted on enter, removed on exit — signals that the turn controls are bound.
#[derive(Resource)]
pub struct TurnControlsBound;

// ─── OnEnter System ─────────────────────────

pub fn bind_turn_controls(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    {
        bind_advance_button();
        bind_recovery_button();
        bind_recovery_action_buttons();
        clear_round_recovery();
        set_round_stall_badges(None);
        set_turn_status("라운드 실행 준비 중...", "status-info");
        set_turn_gate_reason("실행 조건 점검 중...", "status-info");
        log::info!("TurnControls: bound");
    }

    commands.insert_resource(TurnControlsBound);
}

pub fn unbind_turn_controls(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    {
        release_round_flight("manual");
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            set_round_run_controls_locked(&doc, false);
        }
        clear_turn_status();
        clear_round_recovery();
        set_round_stall_badges(None);
        set_turn_gate_reason("", "");
        log::info!("TurnControls: unbound");
    }

    commands.remove_resource::<TurnControlsBound>();
}

// ─── Visibility Sync ────────────────────────

/// Show turn controls only when a round-run capable assignment exists.
pub fn sync_turn_controls_visibility(
    room_state: Res<RoomState>,
    progress: Res<TurnProgressState>,
    connection: Res<ConnectionStatus>,
) {
    let _ = (&room_state, &progress);
    let _ = &connection;

    #[cfg(target_arch = "wasm32")]
    {
        let lifecycle =
            TrpgLifecycleState::from_room_progress(&room_state.status, &progress.room_status);
        let connection_ok = connection_ready(&connection);

        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let Some(panel) = doc.get_element_by_id("turn-controls") else {
            return;
        };
        let _ = panel.set_attribute("style", "");
        let _ = panel.set_attribute("data-lifecycle", lifecycle.css_class());

        let plan_error = read_round_run_plan(&doc).err();
        let (mut can_run, mut reason, mut reason_class) =
            derive_round_control_state(lifecycle, connection_ok, plan_error.as_deref());
        let lock_owner = current_round_flight_owner(&doc);
        let runner_active = auto_round_runner_active(&doc);
        if runner_active {
            can_run = false;
            reason =
                "실행 대기: 자동 라운드 실행 중입니다. 관전 모드에서는 수동 실행이 잠금됩니다."
                    .to_string();
            reason_class = "status-info";
        } else if let Some(owner) = lock_owner.as_deref() {
            if owner != "manual" {
                can_run = false;
                reason = format!("실행 대기: {} 라운드 요청 처리 중입니다.", owner);
                reason_class = "status-info";
            }
        }

        let busy = doc
            .get_element_by_id("advance-turn-btn")
            .and_then(|el| el.dyn_into::<HtmlButtonElement>().ok())
            .and_then(|btn| btn.get_attribute("data-busy"))
            .is_some_and(|v| v == "1");
        let locked = lock_owner.is_some() || runner_active;
        set_round_run_controls_locked(&doc, locked);

        // Sync progress.dm_keeper to DOM input if empty
        if let Some(dm_input) = doc
            .get_element_by_id("round-run-dm")
            .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        {
            if dm_input.value().trim().is_empty() && !progress.dm_keeper.trim().is_empty() {
                dm_input.set_value(progress.dm_keeper.trim());
            }
        }

        let dm_ready = !progress.dm_keeper.trim().is_empty()
            || read_dom_input(&doc, "round-run-dm")
            .or_else(|| read_claimed_keeper_for_current_room(&doc))
            .or_else(|| read_dom_input(&doc, "new-game-dm-select"))
            .is_some();
        let player_pairs_raw = read_dom_text_value(&doc, "round-run-players").unwrap_or_default();
        let mut player_count = parse_player_keeper_pairs(&player_pairs_raw).len();
        if player_count == 0 {
            if read_claimed_actor_keeper_for_current_room(&doc).is_some() {
                player_count = 1;
            }
        }
        let lock_reason = if busy {
            Some("수동 라운드 요청 처리 중".to_string())
        } else if runner_active {
            Some("자동 라운드 실행 중".to_string())
        } else {
            lock_owner
                .as_deref()
                .map(|owner| format!("{} 요청 처리 중", owner))
        };
        let readiness_rows = derive_round_readiness_rows(
            connection_ok,
            lifecycle,
            dm_ready,
            player_count,
            lock_reason.as_deref(),
        );
        set_round_readiness_rows(&doc, &readiness_rows);

        if let Some(btn) = doc
            .get_element_by_id("advance-turn-btn")
            .and_then(|el| el.dyn_into::<HtmlButtonElement>().ok())
        {
            let _ = btn.set_attribute("data-can-run", if can_run { "1" } else { "0" });
            let _ = btn.set_attribute("data-gate-reason", &reason);
            btn.set_title(&reason);
        }

        if !busy {
            set_advance_disabled(!can_run || locked);
            set_turn_status(&reason, reason_class);
        }
        let gate_message = if busy {
            "라운드 실행 중입니다. 완료 후 조건을 다시 계산합니다.".to_string()
        } else if runner_active {
            "실행 대기: 자동 라운드 실행 중입니다. 수동 실행은 잠겨 있습니다.".to_string()
        } else if let Some(owner) = lock_owner {
            format!("실행 대기: {} 라운드 요청 처리 중입니다.", owner)
        } else if can_run {
            "실행 가능: DM/플레이어 keeper 배정이 준비되었습니다.".to_string()
        } else {
            format!("실행 대기: {}", reason)
        };
        set_turn_gate_reason(&gate_message, reason_class);
    }
}

// ─── Event: Advance Button ──────────────────

#[cfg(target_arch = "wasm32")]
fn bind_advance_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc.get_element_by_id("advance-turn-btn") else {
        return;
    };
    if btn.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = btn.set_attribute("data-bound", "1");

    let cb = Closure::wrap(Box::new(move || {
        on_advance_click();
    }) as Box<dyn Fn()>);

    let _ = btn.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref());
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn on_advance_click() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    if is_advance_busy(&doc) {
        return;
    }
    if let Err(reason) = read_advance_gate(&doc) {
        set_turn_status(&format!("실행 불가: {}", reason), "status-warn");
        set_turn_gate_reason(&format!("실행 대기: {}", reason), "status-warn");
        return;
    }
    if let Err(reason) = read_round_run_plan(&doc) {
        set_turn_status(&format!("실행 불가: {}", reason), "status-warn");
        set_turn_gate_reason(&format!("실행 대기: {}", reason), "status-warn");
        return;
    }
    if auto_round_runner_active(&doc) {
        set_turn_status("실행 불가: 자동 라운드 실행 중입니다.", "status-warn");
        set_turn_gate_reason(
            "실행 대기: 자동 라운드 실행이 끝난 뒤 수동 실행이 가능합니다.",
            "status-info",
        );
        return;
    }
    if let Err(reason) = acquire_round_flight(&doc, "manual") {
        set_turn_status(&format!("실행 대기: {}", reason), "status-info");
        set_turn_gate_reason(&format!("실행 대기: {}", reason), "status-info");
        return;
    }

    clear_round_recovery();
    set_round_stall_badges(None);
    set_turn_status("라운드 실행 중...", "status-info");
    set_turn_gate_reason("라운드 실행 요청 전송 중...", "status-info");
    set_advance_busy(true);

    wasm_bindgen_futures::spawn_local(async move {
        match advance_turn().await {
            Ok(RoundRunOutcome::Advanced {
                status,
                has_warning,
            }) => {
                clear_round_recovery();
                set_round_stall_badges(None);
                let css_class = if has_warning {
                    "status-warn"
                } else {
                    "status-ok"
                };
                set_turn_status(&status, css_class);
                set_turn_gate_reason("실행 완료: 다음 라운드 조건을 다시 계산합니다.", css_class);
            }
            Ok(RoundRunOutcome::Stalled {
                status,
                guide,
                summary,
            }) => {
                set_round_recovery(Some(&guide));
                set_round_stall_badges(Some(&summary));
                set_turn_status(&status, "status-warn");
                set_turn_gate_reason(&format!("실행 보류: {}", status), "status-warn");
            }
            Err(e) => {
                let detail = e.as_string().unwrap_or_else(|| format!("{:?}", e));
                log::warn!("Advance turn failed: {}", detail);
                clear_round_recovery();
                set_round_stall_badges(None);
                set_turn_status(&format!("실패: {}", detail), "status-error");
                set_turn_gate_reason(
                    &format!("실행 실패: {}", shorten_reason(&detail, 180)),
                    "status-error",
                );
            }
        }
        set_advance_busy(false);
        release_round_flight("manual");
    });
}

// ─── HTTP: Advance Turn ─────────────────────

#[cfg(target_arch = "wasm32")]
enum RoundRunOutcome {
    Advanced {
        status: String,
        has_warning: bool,
    },
    Stalled {
        status: String,
        guide: String,
        summary: RoundStallSummary,
    },
}

#[cfg(target_arch = "wasm32")]
fn shorten_reason(raw: &str, max_chars: usize) -> String {
    let text = raw.trim().replace('\n', " ");
    if text.chars().count() <= max_chars {
        return text;
    }
    let mut truncated = text
        .chars()
        .take(max_chars.saturating_sub(1))
        .collect::<String>();
    truncated.push('…');
    truncated
}

#[cfg(target_arch = "wasm32")]
fn collect_stall_reasons(json: &Value) -> Vec<String> {
    let mut rows = Vec::new();
    let Some(statuses) = json.get("statuses").and_then(Value::as_array) else {
        return rows;
    };

    for status in statuses {
        let status_name = status
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim();
        if status_name.is_empty() || status_name.eq_ignore_ascii_case("ok") {
            continue;
        }
        let actor_id = status
            .get("actor_id")
            .and_then(Value::as_str)
            .unwrap_or("-")
            .trim();
        let keeper = status
            .get("keeper")
            .and_then(Value::as_str)
            .unwrap_or("-")
            .trim();
        let stage = status
            .get("stage")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        let reason = status
            .get("reason")
            .or_else(|| status.get("error"))
            .or_else(|| status.get("reply"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();

        let mut row = format!(
            "{}({})={} @{}",
            actor_id,
            keeper,
            status_name,
            if stage.is_empty() { "-" } else { stage }
        );
        if !reason.is_empty() {
            row.push_str(&format!(" · {}", shorten_reason(reason, 90)));
        }
        rows.push(row);
        if rows.len() >= 3 {
            break;
        }
    }
    rows
}

#[cfg(target_arch = "wasm32")]
fn count_non_ok_statuses(json: &Value) -> u64 {
    json.get("statuses")
        .and_then(Value::as_array)
        .map(|statuses| {
            statuses
                .iter()
                .filter(|status| {
                    let status_name = status
                        .get("status")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .trim();
                    !status_name.is_empty() && !status_name.eq_ignore_ascii_case("ok")
                })
                .count() as u64
        })
        .unwrap_or(0)
}

#[cfg(target_arch = "wasm32")]
fn preflight_warning_text(json: &Value) -> Option<String> {
    json.get("preflight_warning")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
}

#[cfg(target_arch = "wasm32")]
fn extract_stalled_round_summary(json: &Value) -> RoundStallSummary {
    let summary = json.get("summary");
    let reasons = collect_stall_reasons(json);
    RoundStallSummary {
        successes: summary
            .and_then(|s| s.get("successes"))
            .and_then(Value::as_u64)
            .unwrap_or(0),
        player_successes: summary
            .and_then(|s| s.get("player_successes"))
            .and_then(Value::as_u64)
            .unwrap_or(0),
        dm_success: summary
            .and_then(|s| s.get("dm_success"))
            .and_then(Value::as_bool)
            .unwrap_or(false),
        timeouts: summary
            .and_then(|s| s.get("timeouts"))
            .and_then(Value::as_u64)
            .unwrap_or(0),
        unavailable: summary
            .and_then(|s| s.get("unavailable"))
            .and_then(Value::as_u64)
            .unwrap_or(0),
        first_issue: reasons.first().cloned(),
    }
}

#[cfg(target_arch = "wasm32")]
fn build_stalled_round_guide(
    summary: &RoundStallSummary,
    turn_before: u64,
    turn_after: u64,
) -> String {
    let successes = summary.successes;
    let player_successes = summary.player_successes;
    let dm_success = summary.dm_success;
    let timeouts = summary.timeouts;
    let unavailable = summary.unavailable;

    let mut lines = vec![
        format!(
            "턴 미진행: {} -> {} (라운드 응답은 성공)",
            turn_before, turn_after
        ),
        format!(
            "요약: 성공 {} / 플레이어 성공 {} / DM {} / timeout {} / unavailable {}",
            successes,
            player_successes,
            if dm_success { "성공" } else { "실패" },
            timeouts,
            unavailable
        ),
    ];
    let reasons = summary
        .first_issue
        .as_ref()
        .map(|reason| vec![reason.clone()])
        .unwrap_or_default();
    if !reasons.is_empty() {
        lines.push(format!("차단 원인: {}", reasons.join(" | ")));
    }
    lines.push(
        "권장 조치: 1) keeper 상태 확인 2) actor=keeper 할당/중복 확인 3) timeout 늘려 재실행"
            .to_string(),
    );
    lines.join("\n")
}

#[cfg(target_arch = "wasm32")]
async fn advance_turn() -> Result<RoundRunOutcome, JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let doc = web_sys::window()
        .and_then(|w| w.document())
        .ok_or_else(|| JsValue::from_str("No document"))?;
    let plan = read_round_run_plan(&doc).map_err(|err| JsValue::from_str(&err))?;

    let mut player_keepers = serde_json::Map::new();
    for (actor_id, keeper_name) in &plan.player_keepers {
        player_keepers.insert(actor_id.clone(), Value::String(keeper_name.clone()));
    }

    let url = format!("{}/api/v1/trpg/rounds/run", config::MASC_MCP_URL);
    let body = json!({
        "room_id": config::current_room_id(),
        "dm_keeper": plan.dm_keeper,
        "player_keepers": Value::Object(player_keepers),
        "phase": plan.phase,
        "timeout_sec": plan.timeout_sec,
        "lang": plan.lang,
        "require_claim": true
    })
    .to_string();

    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_mode(web_sys::RequestMode::Cors);
    opts.set_body(&JsValue::from_str(&body));

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    request.headers().set("Content-Type", "application/json")?;

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;

    if !resp.ok() {
        let err_body = JsFuture::from(resp.text()?)
            .await
            .ok()
            .and_then(|v| v.as_string())
            .unwrap_or_default();
        let err_body = err_body.trim();
        if err_body.is_empty() {
            return Err(JsValue::from_str(&format!("HTTP {}", resp.status())));
        }
        return Err(JsValue::from_str(&format!(
            "HTTP {}: {}",
            resp.status(),
            err_body
        )));
    }

    let resp_text = JsFuture::from(resp.text()?)
        .await
        .ok()
        .and_then(|v| v.as_string())
        .unwrap_or_default();
    log::info!("TurnControls: round run response — {}", resp_text);

    if let Ok(json) = serde_json::from_str::<Value>(&resp_text) {
        let turn_before = json.get("turn_before").and_then(Value::as_u64).unwrap_or(0);
        let turn_after = json.get("turn_after").and_then(Value::as_u64).unwrap_or(0);
        let summary_advanced = json
            .get("summary")
            .and_then(|summary| summary.get("advanced"))
            .and_then(Value::as_bool);
        if round_advanced(turn_before, turn_after, summary_advanced) {
            let mut status = format!("라운드 진행: 턴 {} → {}", turn_before, turn_after);
            let mut warnings = Vec::new();
            if let Some(preflight_warning) = preflight_warning_text(&json) {
                warnings.push(format!(
                    "사전 점검 {}",
                    shorten_reason(&preflight_warning, 90)
                ));
            }
            let issue_count = count_non_ok_statuses(&json);
            if issue_count > 0 {
                warnings.push(format!("비정상 응답 {}건", issue_count));
            }
            let has_warning = !warnings.is_empty();
            if has_warning {
                status.push_str(&format!(" · {}", warnings.join(" / ")));
            }
            return Ok(RoundRunOutcome::Advanced {
                status,
                has_warning,
            });
        }
        let stalled_status = format!(
            "턴이 진행되지 않았습니다 ({} → {}).",
            turn_before, turn_after
        );
        let summary = extract_stalled_round_summary(&json);
        let guide = build_stalled_round_guide(&summary, turn_before, turn_after);
        return Ok(RoundRunOutcome::Stalled {
            status: stalled_status,
            guide,
            summary,
        });
    }

    Ok(RoundRunOutcome::Advanced {
        status: "라운드가 진행되었습니다.".to_string(),
        has_warning: false,
    })
}

// ─── DOM Helpers ─────────────────────────────

#[cfg(target_arch = "wasm32")]
fn set_turn_status(text: &str, css_class: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    if let Some(el) = doc.get_element_by_id("turn-control-status") {
        el.set_text_content(Some(text));
        let _ = el.set_attribute("class", css_class);
    }
    if let Some(el) = doc.get_element_by_id("ops-control-state") {
        let class_name = format!("ops-v {}", control_status_to_ops_class(css_class));
        el.set_text_content(Some(text));
        let _ = el.set_attribute("class", &class_name);
        let _ = el.set_attribute("title", text);
    }
}

#[cfg(target_arch = "wasm32")]
fn set_turn_gate_reason(text: &str, css_class: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(el) = doc.get_element_by_id("turn-control-gate") else {
        return;
    };
    el.set_text_content(Some(text));

    let class_name = if css_class.trim().is_empty() {
        "turn-control-gate".to_string()
    } else {
        format!("turn-control-gate {}", css_class)
    };
    let _ = el.set_attribute("class", &class_name);
}

#[cfg(target_arch = "wasm32")]
fn append_round_stall_badge(
    doc: &web_sys::Document,
    container: &Element,
    label: &str,
    value: &str,
    tone_class: &str,
    title: Option<&str>,
) {
    let Ok(badge) = doc.create_element("span") else {
        return;
    };
    badge.set_class_name(&format!("round-run-badge {}", tone_class));
    if let Some(title) = title {
        let _ = badge.set_attribute("title", title);
    }

    let Ok(k) = doc.create_element("span") else {
        return;
    };
    k.set_class_name("badge-k");
    k.set_text_content(Some(label));
    let _ = badge.append_child(&k);

    let Ok(v) = doc.create_element("span") else {
        return;
    };
    v.set_class_name("badge-v");
    v.set_text_content(Some(value));
    let _ = badge.append_child(&v);

    let _ = container.append_child(&badge);
}

#[cfg(target_arch = "wasm32")]
fn set_round_stall_badges(summary: Option<&RoundStallSummary>) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(container) = doc.get_element_by_id("round-run-badges") else {
        return;
    };

    container.set_text_content(None);
    if summary.is_none() {
        let _ = container.set_attribute("style", "display:none");
        return;
    }
    let summary = summary.expect("checked is_some");
    let _ = container.set_attribute("style", "");

    append_round_stall_badge(
        &doc,
        &container,
        "SUCCESS",
        &summary.successes.to_string(),
        if summary.successes > 0 {
            "is-ok"
        } else {
            "is-warn"
        },
        Some("이번 라운드 전체 성공 응답 수"),
    );
    append_round_stall_badge(
        &doc,
        &container,
        "PLAYER",
        &summary.player_successes.to_string(),
        if summary.player_successes > 0 {
            "is-ok"
        } else {
            "is-warn"
        },
        Some("이번 라운드에서 성공한 플레이어 액션 수"),
    );
    append_round_stall_badge(
        &doc,
        &container,
        "DM",
        if summary.dm_success { "ok" } else { "fail" },
        if summary.dm_success {
            "is-ok"
        } else {
            "is-error"
        },
        Some("DM 내레이션/판정 성공 여부"),
    );
    append_round_stall_badge(
        &doc,
        &container,
        "TIMEOUT",
        &summary.timeouts.to_string(),
        if summary.timeouts > 0 {
            "is-warn"
        } else {
            "is-ok"
        },
        Some("턴 타임아웃 발생 횟수"),
    );
    append_round_stall_badge(
        &doc,
        &container,
        "UNAVAILABLE",
        &summary.unavailable.to_string(),
        if summary.unavailable > 0 {
            "is-error"
        } else {
            "is-ok"
        },
        Some("keeper unavailable 발생 횟수"),
    );
    if let Some(issue) = summary.first_issue.as_deref() {
        append_round_stall_badge(
            &doc,
            &container,
            "ISSUE",
            &shorten_reason(issue, 80),
            "is-warn",
            Some(issue),
        );
    }
}

#[cfg(target_arch = "wasm32")]
fn clear_turn_status() {
    set_turn_status("", "");
}

#[cfg(target_arch = "wasm32")]
fn auto_round_runner_active(doc: &web_sys::Document) -> bool {
    doc.get_element_by_id("dashboard")
        .and_then(|el| el.get_attribute("data-round-runner-active"))
        .is_some_and(|value| value == "1")
}

#[cfg(target_arch = "wasm32")]
fn current_round_flight_owner(doc: &web_sys::Document) -> Option<String> {
    doc.get_element_by_id("dashboard")
        .and_then(|el| el.get_attribute("data-round-flight-owner"))
        .map(|owner| owner.trim().to_string())
        .filter(|owner| !owner.is_empty())
}

#[cfg(target_arch = "wasm32")]
fn acquire_round_flight(doc: &web_sys::Document, owner: &str) -> Result<(), String> {
    let Some(dashboard) = doc.get_element_by_id("dashboard") else {
        return Ok(());
    };
    let existing = dashboard
        .get_attribute("data-round-flight-owner")
        .unwrap_or_default()
        .trim()
        .to_string();
    if existing.is_empty() {
        let _ = dashboard.set_attribute("data-round-flight-owner", owner);
        return Ok(());
    }
    if existing == owner {
        return Err("이미 수동 라운드 실행 중입니다.".to_string());
    }
    Err(format!("{} 라운드 실행이 진행 중입니다.", existing))
}

#[cfg(target_arch = "wasm32")]
fn release_round_flight(owner: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(dashboard) = doc.get_element_by_id("dashboard") else {
        return;
    };
    let existing = dashboard
        .get_attribute("data-round-flight-owner")
        .unwrap_or_default()
        .trim()
        .to_string();
    if existing == owner {
        let _ = dashboard.remove_attribute("data-round-flight-owner");
    }
}

#[cfg(target_arch = "wasm32")]
fn set_round_run_controls_locked(doc: &web_sys::Document, locked: bool) {
    if let Some(panel) = doc.get_element_by_id("turn-controls") {
        let _ = panel.set_attribute("data-round-controls-locked", if locked { "1" } else { "0" });
    }
    for id in [
        "round-recovery-refresh",
        "round-recovery-timeout",
        "round-recovery-retry",
    ] {
        if let Some(btn) = doc
            .get_element_by_id(id)
            .and_then(|el| el.dyn_into::<HtmlButtonElement>().ok())
        {
            btn.set_disabled(locked);
        }
    }
    for id in ["round-run-dm", "round-run-players", "round-run-timeout"] {
        if let Some(input) = doc
            .get_element_by_id(id)
            .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        {
            input.set_disabled(locked);
        }
    }
    for id in ["round-run-phase", "round-run-lang"] {
        if let Some(select) = doc
            .get_element_by_id(id)
            .and_then(|el| el.dyn_into::<HtmlSelectElement>().ok())
        {
            select.set_disabled(locked);
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn bind_recovery_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc.get_element_by_id("round-recovery-btn") else {
        return;
    };
    if btn.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = btn.set_attribute("data-bound", "1");

    let cb = Closure::wrap(Box::new(move || {
        toggle_round_recovery();
    }) as Box<dyn Fn()>);
    let _ = btn.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref());
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn bind_recovery_action_buttons() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };

    if let Some(btn) = doc.get_element_by_id("round-recovery-refresh") {
        if btn.get_attribute("data-bound").as_deref() != Some("1") {
            let _ = btn.set_attribute("data-bound", "1");
            let cb = Closure::wrap(Box::new(move || {
                let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                    return;
                };
                if let Some(refresh_btn) = doc
                    .get_element_by_id("new-game-refresh")
                    .and_then(|el| el.dyn_into::<HtmlButtonElement>().ok())
                {
                    refresh_btn.click();
                    set_turn_status("복구 액션: Keeper 새로고침 요청", "status-info");
                } else {
                    set_turn_status(
                        "복구 액션 실패: 새로고침 버튼을 찾지 못했습니다.",
                        "status-error",
                    );
                }
            }) as Box<dyn Fn()>);
            let _ = btn.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref());
            cb.forget();
        }
    }

    if let Some(btn) = doc.get_element_by_id("round-recovery-timeout") {
        if btn.get_attribute("data-bound").as_deref() != Some("1") {
            let _ = btn.set_attribute("data-bound", "1");
            let cb = Closure::wrap(Box::new(move || {
                let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                    return;
                };
                let current = read_dom_input(&doc, "round-run-timeout")
                    .and_then(|raw| raw.parse::<f64>().ok())
                    .filter(|value| *value > 0.0)
                    .unwrap_or(90.0);
                let next = (current + 30.0).min(600.0);
                if let Some(input) = doc
                    .get_element_by_id("round-run-timeout")
                    .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
                {
                    input.set_value(&format!("{:.0}", next));
                    set_turn_status(
                        &format!("복구 액션: timeout {:.0}s → {:.0}s", current, next),
                        "status-info",
                    );
                } else {
                    set_turn_status(
                        "복구 액션 실패: timeout 필드를 찾지 못했습니다.",
                        "status-error",
                    );
                }
            }) as Box<dyn Fn()>);
            let _ = btn.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref());
            cb.forget();
        }
    }

    if let Some(btn) = doc.get_element_by_id("round-recovery-retry") {
        if btn.get_attribute("data-bound").as_deref() != Some("1") {
            let _ = btn.set_attribute("data-bound", "1");
            let cb = Closure::wrap(Box::new(move || {
                let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                    return;
                };
                if is_advance_busy(&doc) {
                    return;
                }
                on_advance_click();
            }) as Box<dyn Fn()>);
            let _ = btn.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref());
            cb.forget();
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn toggle_round_recovery() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc
        .get_element_by_id("round-recovery-btn")
        .and_then(|el| el.dyn_into::<HtmlButtonElement>().ok())
    else {
        return;
    };
    let Some(note) = doc.get_element_by_id("round-recovery-note") else {
        return;
    };
    let is_open = btn.get_attribute("data-open").as_deref() == Some("1");
    if is_open {
        let _ = btn.set_attribute("data-open", "0");
        btn.set_text_content(Some("복구 가이드 보기"));
        let _ = note.set_attribute("style", "display:none");
        return;
    }
    let message = btn
        .get_attribute("data-guide")
        .unwrap_or_else(|| "복구 가이드를 불러올 수 없습니다.".to_string());
    note.set_text_content(Some(&message));
    let _ = note.set_attribute("style", "display:block");
    let _ = btn.set_attribute("data-open", "1");
    btn.set_text_content(Some("복구 가이드 숨기기"));
}

#[cfg(target_arch = "wasm32")]
fn clear_round_recovery() {
    set_round_recovery(None);
}

#[cfg(target_arch = "wasm32")]
fn set_recovery_actions_visible(visible: bool) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    if let Some(actions) = doc.get_element_by_id("round-recovery-actions") {
        let _ = actions.set_attribute("style", if visible { "" } else { "display:none" });
    }
}

#[cfg(target_arch = "wasm32")]
fn set_round_recovery(guide: Option<&str>) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc
        .get_element_by_id("round-recovery-btn")
        .and_then(|el| el.dyn_into::<HtmlButtonElement>().ok())
    else {
        return;
    };
    let note = doc.get_element_by_id("round-recovery-note");

    let guide = guide.unwrap_or("").trim();
    if guide.is_empty() {
        set_recovery_actions_visible(false);
        let _ = btn.set_attribute("style", "display:none");
        let _ = btn.remove_attribute("data-guide");
        let _ = btn.remove_attribute("data-open");
        btn.set_text_content(Some("복구 가이드 보기"));
        if let Some(note) = note {
            note.set_text_content(None);
            let _ = note.set_attribute("style", "display:none");
        }
        return;
    }

    set_recovery_actions_visible(true);
    let _ = btn.set_attribute("style", "");
    let _ = btn.set_attribute("data-guide", guide);
    let _ = btn.set_attribute("data-open", "0");
    btn.set_text_content(Some("복구 가이드 보기"));
    btn.set_title("턴이 진행되지 않았습니다. 원인/조치 가이드를 확인하세요.");
    if let Some(note) = note {
        note.set_text_content(Some(guide));
        let _ = note.set_attribute("style", "display:none");
    }
}

#[cfg(target_arch = "wasm32")]
fn set_advance_disabled(disabled: bool) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    if let Some(el) = doc.get_element_by_id("advance-turn-btn") {
        if let Ok(btn) = el.dyn_into::<HtmlButtonElement>() {
            btn.set_disabled(disabled);
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn set_advance_busy(busy: bool) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    if let Some(el) = doc.get_element_by_id("advance-turn-btn") {
        if let Ok(btn) = el.dyn_into::<HtmlButtonElement>() {
            btn.set_disabled(busy);
            if busy {
                let _ = btn.set_attribute("data-busy", "1");
                let _ = btn.set_attribute("aria-busy", "true");
            } else {
                let _ = btn.remove_attribute("data-busy");
                let _ = btn.remove_attribute("aria-busy");
            }
        }
    }
    let lock_active = current_round_flight_owner(&doc).is_some();
    set_round_run_controls_locked(&doc, busy || lock_active);
}

#[cfg(target_arch = "wasm32")]
fn is_advance_busy(doc: &web_sys::Document) -> bool {
    doc.get_element_by_id("advance-turn-btn")
        .and_then(|el| el.dyn_into::<HtmlButtonElement>().ok())
        .and_then(|btn| btn.get_attribute("data-busy"))
        .is_some_and(|v| v == "1")
}

#[cfg(target_arch = "wasm32")]
fn read_advance_gate(doc: &web_sys::Document) -> Result<(), String> {
    let Some(btn) = doc
        .get_element_by_id("advance-turn-btn")
        .and_then(|el| el.dyn_into::<HtmlButtonElement>().ok())
    else {
        return Err("라운드 실행 버튼을 찾을 수 없습니다.".to_string());
    };
    let can_run = btn.get_attribute("data-can-run").is_some_and(|v| v == "1");
    if can_run {
        Ok(())
    } else {
        Err(btn
            .get_attribute("data-gate-reason")
            .unwrap_or_else(|| "라운드 제어 상태를 아직 계산 중입니다.".to_string()))
    }
}

#[cfg(target_arch = "wasm32")]
struct RoundRunPlan {
    dm_keeper: String,
    phase: String,
    timeout_sec: f64,
    lang: String,
    player_keepers: Vec<(String, String)>,
}

#[cfg(target_arch = "wasm32")]
fn read_dom_text_value(doc: &web_sys::Document, id: &str) -> Option<String> {
    let el = doc.get_element_by_id(id)?;
    if let Ok(input) = el.clone().dyn_into::<HtmlInputElement>() {
        return Some(input.value());
    }
    if let Ok(select) = el.dyn_into::<HtmlSelectElement>() {
        return Some(select.value());
    }
    None
}

#[cfg(target_arch = "wasm32")]
fn read_dom_input(doc: &web_sys::Document, id: &str) -> Option<String> {
    let value = read_dom_text_value(doc, id)?;
    let trimmed = value.trim().to_string();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

#[cfg(target_arch = "wasm32")]
fn claim_matches_current_room(doc: &web_sys::Document) -> bool {
    let claimed_room = read_dom_input(doc, "claimed-room-id").unwrap_or_default();
    !claimed_room.is_empty() && claimed_room == config::current_room_id()
}

#[cfg(target_arch = "wasm32")]
fn read_claimed_keeper_for_current_room(doc: &web_sys::Document) -> Option<String> {
    if claim_matches_current_room(doc) {
        read_dom_input(doc, "claimed-keeper")
    } else {
        None
    }
}

#[cfg(target_arch = "wasm32")]
fn read_claimed_actor_keeper_for_current_room(
    doc: &web_sys::Document,
) -> Option<(String, String)> {
    if !claim_matches_current_room(doc) {
        return None;
    }
    let claimed_actor = read_dom_input(doc, "claimed-actor-id").unwrap_or_default();
    let claimed_keeper = read_dom_input(doc, "claimed-keeper").unwrap_or_default();
    if claimed_actor.is_empty() || claimed_keeper.is_empty() {
        None
    } else {
        Some((claimed_actor, claimed_keeper))
    }
}

#[cfg(target_arch = "wasm32")]
fn parse_player_keeper_pairs(raw: &str) -> Vec<(String, String)> {
    raw.split(',')
        .filter_map(|part| {
            let pair = part.trim();
            if pair.is_empty() {
                return None;
            }
            let mut pieces = pair.splitn(2, '=');
            let actor_id = pieces.next()?.trim();
            let keeper = pieces.next()?.trim();
            if actor_id.is_empty() || keeper.is_empty() {
                None
            } else {
                Some((actor_id.to_string(), keeper.to_string()))
            }
        })
        .collect::<Vec<_>>()
}

#[cfg(target_arch = "wasm32")]
fn read_round_run_plan(doc: &web_sys::Document) -> Result<RoundRunPlan, String> {
    let dm_keeper = read_dom_input(doc, "round-run-dm")
        .or_else(|| read_claimed_keeper_for_current_room(doc))
        .or_else(|| read_dom_input(doc, "new-game-dm-select"))
        .unwrap_or_default();
    if dm_keeper.is_empty() {
        return Err(
            "DM keeper가 설정되지 않았습니다. `새 게임`에서 DM을 선택하거나 현재 방에서 DM claim을 먼저 완료하세요."
                .to_string(),
        );
    }

    let phase = read_dom_input(doc, "round-run-phase").unwrap_or_else(|| "round".to_string());
    let lang = read_dom_input(doc, "round-run-lang").unwrap_or_else(|| "ko".to_string());
    let timeout_sec = read_dom_input(doc, "round-run-timeout")
        .and_then(|raw| raw.parse::<f64>().ok())
        .filter(|value| *value > 0.0)
        .unwrap_or(90.0);

    let player_pairs_raw = read_dom_text_value(doc, "round-run-players").unwrap_or_default();
    let mut player_keepers = parse_player_keeper_pairs(&player_pairs_raw);
    if player_keepers.is_empty() {
        if let Some((claimed_actor, claimed_keeper)) = read_claimed_actor_keeper_for_current_room(doc)
        {
            player_keepers.push((claimed_actor, claimed_keeper));
        }
    }
    if player_keepers.is_empty() {
        return Err(
            "player keepers가 없습니다. `새 게임`에서 AI PLAYER 선택 후 `파티 자동 할당`으로 actor→keeper를 채우세요."
                .to_string(),
        );
    }

    Ok(RoundRunPlan {
        dm_keeper,
        phase: if phase.is_empty() {
            "round".to_string()
        } else {
            phase
        },
        timeout_sec,
        lang: if lang.is_empty() {
            "ko".to_string()
        } else {
            lang
        },
        player_keepers,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derive_round_control_state_requires_running_or_stopped() {
        let (can_run, reason, css) =
            derive_round_control_state(TrpgLifecycleState::Lobby, true, None);
        assert!(!can_run);
        assert!(reason.contains("실행 대기"));
        assert_eq!(css, "status-info");
    }

    #[test]
    fn derive_round_control_state_requires_connection() {
        let (can_run, reason, css) =
            derive_round_control_state(TrpgLifecycleState::Running, false, None);
        assert!(!can_run);
        assert!(reason.contains("엔진 연결"));
        assert_eq!(css, "status-info");
    }

    #[test]
    fn derive_round_control_state_requires_plan() {
        let (can_run, reason, css) = derive_round_control_state(
            TrpgLifecycleState::Running,
            true,
            Some("player keepers가 없습니다"),
        );
        assert!(!can_run);
        assert!(reason.contains("준비 필요"));
        assert_eq!(css, "status-warn");
    }

    #[test]
    fn derive_round_control_state_allows_run_when_ready() {
        let (can_run, reason, css) =
            derive_round_control_state(TrpgLifecycleState::Running, true, None);
        assert!(can_run);
        assert!(reason.contains("실행 가능"));
        assert_eq!(css, "status-ok");
    }

    #[test]
    fn connection_ready_true_only_for_connected() {
        assert!(connection_ready(&ConnectionStatus::Connected));
        assert!(!connection_ready(&ConnectionStatus::Disconnected));
        assert!(!connection_ready(&ConnectionStatus::Connecting));
        assert!(!connection_ready(&ConnectionStatus::Failed));
    }

    #[test]
    fn round_advanced_prefers_summary_flag() {
        assert!(!round_advanced(3, 4, Some(false)));
        assert!(round_advanced(4, 4, Some(true)));
    }

    #[test]
    fn round_advanced_falls_back_to_turn_delta() {
        assert!(round_advanced(2, 3, None));
        assert!(!round_advanced(2, 2, None));
    }

    #[test]
    fn round_readiness_rows_all_ok_when_ready() {
        let rows = derive_round_readiness_rows(true, TrpgLifecycleState::Running, true, 4, None);
        assert_eq!(rows.len(), 5);
        assert!(rows.iter().all(|row| row.ok));
    }

    #[test]
    fn round_readiness_rows_report_missing_requirements() {
        let rows = derive_round_readiness_rows(
            false,
            TrpgLifecycleState::Lobby,
            false,
            0,
            Some("자동 라운드 실행 중"),
        );
        assert_eq!(rows.len(), 5);
        assert_eq!(rows[0].label, "엔진 연결");
        assert!(!rows[0].ok);
        assert_eq!(rows[1].label, "세션 상태");
        assert!(!rows[1].ok);
        assert_eq!(rows[4].label, "실행 락");
        assert!(!rows[4].ok);
        assert!(rows[4].detail.contains("자동"));
    }
}
