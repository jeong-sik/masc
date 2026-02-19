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
    state.label()
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
        ConnectionStatus::Connected => "connected",
        ConnectionStatus::Connecting => "connecting",
        ConnectionStatus::Reconnecting(_, _) => "reconnecting",
        ConnectionStatus::Disconnected => "disconnected",
        ConnectionStatus::Failed => "failed",
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
        return "Auto Run 진행 중입니다. 이벤트 수신을 기다리세요.".to_string();
    }
    if !lifecycle.accepts_player_input() {
        return match lifecycle {
            TrpgLifecycleState::Loading => {
                "로딩 중입니다. 상태 동기화 완료를 기다리세요.".to_string()
            }
            TrpgLifecycleState::Stopped => {
                "세션이 멈춰 있습니다. Start/Run으로 재개하세요.".to_string()
            }
            TrpgLifecycleState::Ended => {
                "세션이 종료되었습니다. New Game으로 시작하세요.".to_string()
            }
            TrpgLifecycleState::Unavailable => {
                "엔진/키퍼 연결을 복구한 뒤 다시 시도하세요.".to_string()
            }
            TrpgLifecycleState::Lobby => "세션을 시작한 뒤 Run Round를 실행하세요.".to_string(),
            TrpgLifecycleState::Unknown => "상태 확인 후 Run Round를 다시 실행하세요.".to_string(),
            TrpgLifecycleState::Running => "진행 상태를 확인하세요.".to_string(),
        };
    }
    if has_actor_issues {
        return "keeper 상태를 확인한 뒤 Run Round를 다시 실행하세요.".to_string();
    }

    let actor = current_actor.trim();
    if actor.is_empty() || actor == "-" {
        "Run Round를 실행하거나 플레이어 액션을 입력하세요.".to_string()
    } else {
        format!("{} 응답을 기다리는 중입니다.", actor)
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
fn lifecycle_is_done_node(lifecycle: TrpgLifecycleState, node_state: &str) -> bool {
    match lifecycle {
        TrpgLifecycleState::Lobby => false,
        TrpgLifecycleState::Loading => node_state == "lobby",
        TrpgLifecycleState::Running => node_state == "lobby",
        TrpgLifecycleState::Stopped => matches!(node_state, "lobby" | "running"),
        TrpgLifecycleState::Ended => matches!(node_state, "lobby" | "running" | "stopped"),
        TrpgLifecycleState::Unavailable | TrpgLifecycleState::Unknown => false,
    }
}

#[cfg(target_arch = "wasm32")]
fn lifecycle_active_node(lifecycle: TrpgLifecycleState) -> Option<&'static str> {
    match lifecycle {
        TrpgLifecycleState::Lobby => Some("lobby"),
        TrpgLifecycleState::Loading => Some("recover"),
        TrpgLifecycleState::Running => Some("running"),
        TrpgLifecycleState::Stopped => Some("stopped"),
        TrpgLifecycleState::Ended => Some("ended"),
        TrpgLifecycleState::Unavailable => Some("unavailable"),
        TrpgLifecycleState::Unknown => None,
    }
}

#[cfg(target_arch = "wasm32")]
fn lifecycle_hint(lifecycle: TrpgLifecycleState, runner_running: bool) -> String {
    match lifecycle {
        TrpgLifecycleState::Lobby => {
            "LOBBY 단계: 새 게임에서 DM/플레이어를 배정하고 세션 시작을 실행하세요.".to_string()
        }
        TrpgLifecycleState::Loading => {
            "SESSION STARTING 단계: 초기화/동기화 중입니다. 완료되면 RUNNING으로 전환됩니다."
                .to_string()
        }
        TrpgLifecycleState::Running => {
            if runner_running {
                "RUNNING 단계: 자동 라운드가 순환 중입니다. 이벤트 수신을 기다리세요.".to_string()
            } else {
                "RUNNING 단계: 라운드 실행 또는 플레이어 액션으로 다음 페이즈로 진행됩니다."
                    .to_string()
            }
        }
        TrpgLifecycleState::Stopped => {
            "STOPPED 단계: 세션은 유지되며 재개 가능합니다. 조건을 점검 후 다시 실행하세요."
                .to_string()
        }
        TrpgLifecycleState::Ended => {
            "ENDED 단계: 현재 세션이 종료되었습니다. 새 게임으로 새 라운드 루프를 시작하세요."
                .to_string()
        }
        TrpgLifecycleState::Unavailable => {
            "UNAVAILABLE 단계: keeper/엔진 연결 문제입니다. 연결 복구 후 재시도하세요.".to_string()
        }
        TrpgLifecycleState::Unknown => {
            "상태 불명: LOBBY → RUNNING ↔ STOPPED → ENDED 순서를 기준으로 로그를 확인하세요."
                .to_string()
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn sync_lifecycle_diagram(
    document: &web_sys::Document,
    lifecycle: TrpgLifecycleState,
    runner_running: bool,
) {
    let active = lifecycle_active_node(lifecycle);
    if let Ok(nodes) = document.query_selector_all("#lifecycle-diagram .lifecycle-node") {
        for idx in 0..nodes.length() {
            let Some(node) = nodes.item(idx) else {
                continue;
            };
            let Some(el) = node.dyn_ref::<web_sys::Element>() else {
                continue;
            };
            let state = el.get_attribute("data-state").unwrap_or_default();
            let _ = el.class_list().remove_1("is-active");
            let _ = el.class_list().remove_1("is-done");
            let _ = el.class_list().remove_1("is-error");

            if lifecycle_is_done_node(lifecycle, &state) {
                let _ = el.class_list().add_1("is-done");
            }
            if active == Some(state.as_str()) {
                let _ = el.class_list().add_1("is-active");
            }
            if lifecycle == TrpgLifecycleState::Unavailable && state == "unavailable" {
                let _ = el.class_list().add_1("is-error");
            }
        }
    }

    if let Some(hint) = document.get_element_by_id("lifecycle-diagram-hint") {
        let message = lifecycle_hint(lifecycle, runner_running);
        hint.set_text_content(Some(&message));
        let _ = hint.set_attribute("title", &message);
    }
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
        format!("{}/{} alive", alive_party, total_party)
    };
    let (issues_summary, has_actor_issues) = summarize_actor_issues(&progress);

    let current_status = if !lifecycle.accepts_player_input() {
        lifecycle.label_ko()
    } else if current_actor != "-" {
        "thinking"
    } else {
        "waiting"
    };

    let input_status = if lifecycle.accepts_player_input() {
        "enabled"
    } else {
        "disabled"
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
        (format!("mismatch: {}", reasons.join(" · ")), "status-error")
    } else if progress.last_event.trim().is_empty() {
        ("waiting event".to_string(), "status-idle")
    } else {
        (
            format!("ok · {}", progress.last_event.trim()),
            "status-active",
        )
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
        format!("auto-run {} rounds", runner_rounds)
    } else {
        "idle".to_string()
    };
    let next_action =
        build_next_action_hint(lifecycle, runner_running, &current_actor, has_actor_issues);

    let connection_label = connection_status_label(&connection);
    let connection_class = connection_status_class(&connection);

    #[cfg(not(target_arch = "wasm32"))]
    let _ = (&sync_class, &runner_last_result);

    let snapshot = format!(
        "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}",
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
                "room {} · {}",
                room_id,
                lifecycle.label_ko()
            )));
            let _ = room_status_el.set_attribute("data-lifecycle", lifecycle.css_class());
            let _ = room_status_el.set_attribute(
                "title",
                &format!(
                    "{} | turn {} | phase {} | raw {}",
                    lifecycle.help_text(),
                    turn,
                    phase,
                    room_status_key
                ),
            );
        }

        let room_id = crate::config::current_room_id();
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
            &lifecycle_hint(lifecycle, runner_running),
            if lifecycle.accepts_player_input() {
                "status-active"
            } else {
                room_class
            },
        );
        set_ops_hud_value(&document, "ops-sync-state", &sync_state, sync_class);
        sync_lifecycle_diagram(&document, lifecycle, runner_running);

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
                    "DM: {} · Players: {}",
                    inferred_dm,
                    inferred_player_pairs.join(", ")
                )));
                let _ = summary.set_attribute("style", "display:block");
            }
        }

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
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">Room</span><span class=\"round-sync-value\">{room_id}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">Lifecycle</span><span class=\"round-sync-value {room_class}\">{lifecycle}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">Turn Sync</span><span class=\"round-sync-value {turn_sync_class}\">room {room_turn} / progress {progress_turn}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">Phase Sync</span><span class=\"round-sync-value {phase_sync_class}\">room {room_phase} / progress {progress_phase}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">Last Event</span><span class=\"round-sync-value\">{last_event}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">Last Result</span><span class=\"round-sync-value\">{last_result}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">Runner</span><span class=\"round-sync-value\">{runner_state}</span></div>",
                    "<div class=\"round-sync-row\"><span class=\"round-sync-label\">Runner Resp</span><span class=\"round-sync-value\">{runner_preview}</span></div>"
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
            html_escape(&format!("{} ({})", lifecycle.label(), lifecycle.label_ko()));
        let html = format!(
            r#"
<div class="turn-runtime-grid">
  <div class="turn-runtime-item turn-runtime-item-wide"><span class="k">Lifecycle</span><span class="v {lifecycle_class}">{lifecycle_label}</span></div>
  <div class="turn-runtime-item turn-runtime-item-wide"><span class="k">Definition</span><span class="v">{lifecycle_help}</span></div>
  <div class="turn-runtime-item"><span class="k">State</span><span class="v {room_class}">{room}</span></div>
  <div class="turn-runtime-item"><span class="k">Turn</span><span class="v">{turn}</span></div>
  <div class="turn-runtime-item"><span class="k">Phase</span><span class="v">{phase}</span></div>
  <div class="turn-runtime-item"><span class="k">Input</span><span class="v {input_class}">{input}</span></div>
  <div class="turn-runtime-item"><span class="k">Now</span><span class="v">{current} · {current_status}</span></div>
  <div class="turn-runtime-item"><span class="k">Next</span><span class="v">{next}</span></div>
  <div class="turn-runtime-item"><span class="k">Last</span><span class="v">{last}</span></div>
  <div class="turn-runtime-item turn-runtime-item-wide"><span class="k">Issues</span><span class="v {issues_class}">{issues}</span></div>
  <div class="turn-runtime-item turn-runtime-item-wide"><span class="k">Next Action</span><span class="v">{next_action}</span></div>
  <div class="turn-runtime-item"><span class="k">Party</span><span class="v {party_class}">{party}</span></div>
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
        assert_eq!(hint, "keeper 상태를 확인한 뒤 Run Round를 다시 실행하세요.");
    }

    #[test]
    fn next_action_waits_for_current_actor_when_running() {
        let hint = build_next_action_hint(TrpgLifecycleState::Running, false, "p03", false);
        assert_eq!(hint, "p03 응답을 기다리는 중입니다.");
    }
}
