//! Workspace hub — workspace management, local-storage persistence, and workspace-selector UI.

use serde_json::{json, Value};
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use wasm_bindgen_futures::JsFuture;

use crate::dom::escape::html_escape;
use crate::game::lifecycle::TrpgLifecycleState;

use super::mcp_rpc::mcp_tool_call;
use super::{
    actor_admin_set_status, actor_admin_workspace_id, clear_trpg_dom, refresh_actor_admin_list,
    render_auto_round_toggle, set_current_workspace_id, set_element_display,
    sync_session_pause_buttons, unique_non_empty,
};

const RECENT_WORKSPACES_STORAGE_KEY: &str = "masc_viewer_recent_workspaces";
pub(super) const KNOWN_WORKSPACES_STORAGE_KEY: &str = "masc_viewer_known_workspaces";
pub(super) const WORKSPACE_HUB_VISIBLE_STORAGE_KEY: &str = "masc_viewer_workspace_hub_visible";
pub(super) const WORKSPACE_HUB_RUNNING_ONLY_STORAGE_KEY: &str =
    "masc_viewer_workspace_hub_running_only";
const INLINE_SELECTOR_MAX_OPTIONS: usize = 5;
const WORKSPACE_AUTO_FOCUS_DEFAULT_WORKSPACE_ONLY: bool = true;
const WORKSPACE_AUTO_FOCUS_SCORE_RUNNING: u8 = 4;
const WORKSPACE_AUTO_FOCUS_SCORE_IDLE: u8 = 3;
const WORKSPACE_AUTO_FOCUS_SCORE_STOPPED: u8 = 2;
const WORKSPACE_AUTO_FOCUS_SCORE_LOADING: u8 = 1;

pub(super) fn load_recent_workspaces() -> Vec<String> {
    let raw = web_sys::window()
        .and_then(|w| w.local_storage().ok().flatten())
        .and_then(|storage| {
            storage
                .get_item(RECENT_WORKSPACES_STORAGE_KEY)
                .ok()
                .flatten()
        })
        .unwrap_or_default();
    unique_non_empty(
        raw.split('\n')
            .filter_map(crate::config::sanitize_workspace_id)
            .collect::<Vec<_>>(),
    )
}

fn save_recent_workspaces(workspaces: &[String]) {
    let value = workspaces.join("\n");
    if let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten()) {
        let _ = storage.set_item(RECENT_WORKSPACES_STORAGE_KEY, &value);
    }
}

pub(super) fn remember_recent_workspace(workspace_id: &str) {
    let Some(workspace) = crate::config::sanitize_workspace_id(workspace_id) else {
        return;
    };
    let mut workspaces = load_recent_workspaces();
    workspaces.retain(|existing| existing != &workspace);
    workspaces.insert(0, workspace);
    if workspaces.len() > 12 {
        workspaces.truncate(12);
    }
    save_recent_workspaces(&workspaces);
}

#[derive(Debug, Clone)]
pub(super) struct WorkspaceSnapshot {
    pub(super) id: String,
    pub(super) status: String,
    pub(super) turn: u32,
    pub(super) phase: String,
    pub(super) agent_count: i64,
    pub(super) task_count: i64,
}

pub(super) fn workspace_lane_label(status: &str) -> &'static str {
    TrpgLifecycleState::from_status(status).lane()
}

fn workspace_display_label(workspace_id: &str) -> String {
    if workspace_id.eq_ignore_ascii_case(crate::config::DEFAULT_WORKSPACE_ID) {
        format!("{} (기본 방)", crate::config::DEFAULT_WORKSPACE_ID)
    } else {
        workspace_id.to_string()
    }
}

fn auto_focus_score(status: &str) -> Option<u8> {
    match TrpgLifecycleState::from_status(status) {
        TrpgLifecycleState::Running => Some(WORKSPACE_AUTO_FOCUS_SCORE_RUNNING),
        TrpgLifecycleState::Idle => Some(WORKSPACE_AUTO_FOCUS_SCORE_IDLE),
        TrpgLifecycleState::Stopped => Some(WORKSPACE_AUTO_FOCUS_SCORE_STOPPED),
        TrpgLifecycleState::Loading => Some(WORKSPACE_AUTO_FOCUS_SCORE_LOADING),
        _ => None,
    }
}

fn select_workspace_for_ended_default(
    current_workspace: &str,
    workspaces: &[WorkspaceSnapshot],
) -> Option<String> {
    if WORKSPACE_AUTO_FOCUS_DEFAULT_WORKSPACE_ONLY
        && !current_workspace.eq_ignore_ascii_case(crate::config::DEFAULT_WORKSPACE_ID)
    {
        return None;
    }

    let current_is_ended = workspaces
        .iter()
        .find(|workspace| workspace.id.eq_ignore_ascii_case(current_workspace))
        .map(|workspace| {
            TrpgLifecycleState::from_status(&workspace.status) == TrpgLifecycleState::Ended
        })
        .unwrap_or(false);
    if !current_is_ended {
        return None;
    }

    workspaces
        .iter()
        .filter(|workspace| !workspace.id.eq_ignore_ascii_case(current_workspace))
        .filter_map(|workspace| {
            auto_focus_score(&workspace.status)
                .map(|score| (score, workspace.turn, workspace.id.clone()))
        })
        .max_by_key(|(score, turn, _)| (*score, *turn))
        .map(|(_, _, id)| id)
}

#[cfg(test)]
mod tests {
    use super::{
        inline_selector_workspaces, select_workspace_for_ended_default, WorkspaceSnapshot,
    };

    fn snapshot(id: &str, status: &str, turn: u32) -> WorkspaceSnapshot {
        WorkspaceSnapshot {
            id: id.to_string(),
            status: status.to_string(),
            turn,
            phase: "phase".to_string(),
            agent_count: 0,
            task_count: 0,
        }
    }

    #[test]
    fn ended_default_prefers_running_over_idle() {
        let workspaces = vec![
            snapshot("default", "ended", 11),
            snapshot("idle-workspace", "idle", 99),
            snapshot("running-workspace", "running", 1),
        ];
        assert_eq!(
            select_workspace_for_ended_default("default", &workspaces),
            Some("running-workspace".to_string())
        );
    }

    #[test]
    fn ended_default_uses_turn_as_tiebreaker_within_same_lane() {
        let workspaces = vec![
            snapshot("default", "ended", 4),
            snapshot("run-a", "running", 2),
            snapshot("run-b", "running", 7),
        ];
        assert_eq!(
            select_workspace_for_ended_default("default", &workspaces),
            Some("run-b".to_string())
        );
    }

    #[test]
    fn non_default_workspace_never_auto_switches() {
        let workspaces = vec![
            snapshot("custom", "ended", 4),
            snapshot("run-b", "running", 7),
        ];
        assert_eq!(
            select_workspace_for_ended_default("custom", &workspaces),
            None
        );
    }

    #[test]
    fn default_workspace_without_ended_status_does_not_switch() {
        let workspaces = vec![
            snapshot("default", "running", 4),
            snapshot("run-b", "running", 7),
        ];
        assert_eq!(
            select_workspace_for_ended_default("default", &workspaces),
            None
        );
    }

    #[test]
    fn ended_default_returns_none_when_no_eligible_target_exists() {
        let workspaces = vec![
            snapshot("default", "ended", 4),
            snapshot("archived", "ended", 1),
            snapshot("broken", "unavailable", 0),
        ];
        assert_eq!(
            select_workspace_for_ended_default("default", &workspaces),
            None
        );
    }

    #[test]
    fn inline_selector_workspaces_keeps_known_workspaces_when_selected_is_default() {
        let known = vec![
            "default".to_string(),
            "alpha-workspace".to_string(),
            "beta-workspace".to_string(),
        ];
        let workspaces = inline_selector_workspaces("default", &known);
        assert_eq!(
            workspaces,
            vec![
                "default".to_string(),
                "alpha-workspace".to_string(),
                "beta-workspace".to_string()
            ]
        );
    }

    #[test]
    fn inline_selector_workspaces_prioritizes_selected_workspace_and_dedups() {
        let known = vec![
            "alpha-workspace".to_string(),
            "beta-workspace".to_string(),
            "default".to_string(),
        ];
        let workspaces = inline_selector_workspaces("beta-workspace", &known);
        assert_eq!(
            workspaces,
            vec![
                "beta-workspace".to_string(),
                "default".to_string(),
                "alpha-workspace".to_string()
            ]
        );
    }

    #[test]
    fn inline_selector_workspaces_caps_option_count() {
        let known = (0..20)
            .map(|idx| format!("workspace-{idx:02}"))
            .collect::<Vec<_>>();
        let workspaces = inline_selector_workspaces("current-workspace", &known);
        assert_eq!(workspaces.len(), 5);
        assert_eq!(workspaces[0], "current-workspace");
        assert_eq!(workspaces[1], "default");
    }

    #[test]
    fn inline_selector_workspaces_prioritizes_non_generated_ids() {
        let known = vec![
            "adventure-1771512523460".to_string(),
            "workspace-current-1772042447265-497".to_string(),
            "alpha-workspace".to_string(),
            "beta-workspace".to_string(),
        ];
        let workspaces = inline_selector_workspaces("current-workspace", &known);
        assert_eq!(
            workspaces,
            vec![
                "current-workspace".to_string(),
                "default".to_string(),
                "alpha-workspace".to_string(),
                "beta-workspace".to_string(),
                "adventure-1771512523460".to_string()
            ]
        );
    }
}

fn render_workspace_hub(
    doc: &web_sys::Document,
    workspaces: &[WorkspaceSnapshot],
    selected_workspace: &str,
) {
    let Some(hub) = doc.get_element_by_id("workspace-hub") else {
        return;
    };
    let running_only = load_workspace_hub_running_only();
    let mut current = Vec::new();
    let mut running = Vec::new();
    let mut stopped = Vec::new();
    let mut idle = Vec::new();
    let mut unavailable = Vec::new();
    let mut ended_hidden_count = 0usize;

    for workspace in workspaces {
        let lane = workspace_lane_label(&workspace.status);
        let is_current = workspace.id == selected_workspace;
        let current_attr = if is_current {
            " data-current=\"1\""
        } else {
            " data-current=\"0\""
        };
        let status_text = if workspace.status.trim().is_empty() {
            "unknown".to_string()
        } else {
            workspace.status.clone()
        };
        let lifecycle = TrpgLifecycleState::from_status(&status_text);
        let card = format!(
            concat!(
                "<button class=\"workspace-chip\" data-workspace-id=\"{id}\" data-workspace-status=\"{status}\"{current}>",
                "<span class=\"workspace-chip-id\">{label}<span class=\"workspace-chip-state {state_class}\">{state_label}</span></span>",
                "<span class=\"workspace-chip-meta\">turn {turn} · {phase} · a{agents}/t{tasks}</span>",
                "</button>"
            ),
            id = html_escape(&workspace.id),
            label = html_escape(&workspace_display_label(&workspace.id)),
            status = html_escape(&status_text),
            current = current_attr,
            state_class = lifecycle.css_class(),
            state_label = lifecycle.label_ko(),
            turn = workspace.turn,
            phase = html_escape(&workspace.phase),
            agents = workspace.agent_count,
            tasks = workspace.task_count
        );
        if is_current {
            current.push(card);
            continue;
        }

        match lane {
            "running" => running.push(card),
            "stopped" => stopped.push(card),
            "unavailable" => unavailable.push(card),
            "ended" => ended_hidden_count += 1,
            _ => idle.push(card),
        }
    }

    let lane_html = |title: &str, rows: Vec<String>, lane: &str| -> String {
        let body = if rows.is_empty() {
            "<div class=\"workspace-chip-empty\">(없음)</div>".to_string()
        } else {
            rows.join("")
        };
        format!(
            "<div class=\"workspace-lane\" data-lane=\"{lane}\"><div class=\"workspace-lane-title\">{title}</div><div class=\"workspace-chip-list\">{body}</div></div>",
            lane = lane,
            title = title,
            body = body
        )
    };

    let previous_count = running.len() + stopped.len() + idle.len() + unavailable.len();
    let hidden_ended_note = if ended_hidden_count > 0 {
        format!(" · 종료 {}개 숨김", ended_hidden_count)
    } else {
        String::new()
    };
    let lanes_html = if running_only {
        format!(
            "{}{}",
            lane_html("현재 게임", current, "current"),
            lane_html("진행 중", running, "running")
        )
    } else {
        format!(
            "{}{}{}{}{}",
            lane_html("현재 게임", current, "current"),
            lane_html("진행 중", running, "running"),
            lane_html("멈춤", stopped, "stopped"),
            lane_html("대기", idle, "idle"),
            lane_html("오류", unavailable, "unavailable")
        )
    };
    let current_text = crate::config::sanitize_workspace_id(selected_workspace)
        .unwrap_or_else(|| crate::config::DEFAULT_WORKSPACE_ID.to_string());
    let current_label = workspace_display_label(&current_text);
    let html = format!(
        concat!(
            "<div class=\"workspace-hub-tools\">",
            "<span class=\"workspace-hub-summary\">현재 게임: <code>{current}</code> · 표시 {previous_count}개{hidden_ended}</span>",
            "<button id=\"workspace-hub-running-toggle\" class=\"workspace-hub-filter\" type=\"button\" aria-pressed=\"{pressed}\">",
            "진행 중만",
            "</button>",
            "</div>",
            "{lanes}"
        ),
        current = html_escape(&current_label),
        previous_count = previous_count,
        hidden_ended = hidden_ended_note,
        pressed = if running_only { "true" } else { "false" },
        lanes = lanes_html
    );
    let _ = hub.set_attribute("data-running-only", if running_only { "1" } else { "0" });
    hub.set_inner_html(&html);
}

fn bind_workspace_hub_buttons(doc: &web_sys::Document) {
    if let Ok(nodes) = doc.query_selector_all("#workspace-hub .workspace-chip") {
        for i in 0..nodes.length() {
            let Some(node) = nodes.item(i) else { continue };
            let Some(el) = node.dyn_ref::<web_sys::Element>() else {
                continue;
            };
            if el.get_attribute("data-bound").as_deref() == Some("1") {
                continue;
            }
            let Some(workspace_id) = el.get_attribute("data-workspace-id") else {
                continue;
            };
            let _ = el.set_attribute("data-bound", "1");
            let workspace_copy = workspace_id.clone();
            let cb = Closure::wrap(Box::new(move || {
                let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                    return;
                };
                apply_workspace_switch_from_ui(&doc, &workspace_copy, false);
            }) as Box<dyn FnMut()>);
            let _ = el.dyn_ref::<web_sys::EventTarget>().map(|target| {
                target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
            });
            cb.forget();
        }
    }

    if let Some(toggle) = doc.get_element_by_id("workspace-hub-running-toggle") {
        if toggle.get_attribute("data-bound").as_deref() != Some("1") {
            let _ = toggle.set_attribute("data-bound", "1");
            let cb = Closure::wrap(Box::new(move || {
                let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                    return;
                };
                let pressed = doc
                    .get_element_by_id("workspace-hub-running-toggle")
                    .and_then(|el| el.get_attribute("aria-pressed"))
                    .map(|v| v == "true")
                    .unwrap_or(false);
                save_workspace_hub_running_only(!pressed);
                let doc_for_fetch = doc.clone();
                wasm_bindgen_futures::spawn_local(async move {
                    let _ = refresh_workspaces_from_server(&doc_for_fetch).await;
                });
            }) as Box<dyn FnMut()>);
            let _ = toggle.dyn_ref::<web_sys::EventTarget>().map(|target| {
                target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
            });
            cb.forget();
        }
    }
}

fn sync_workspace_hub_selection(doc: &web_sys::Document, selected_workspace: &str) {
    let Ok(nodes) = doc.query_selector_all("#workspace-hub .workspace-chip") else {
        return;
    };
    for i in 0..nodes.length() {
        let Some(node) = nodes.item(i) else { continue };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };
        let workspace = el.get_attribute("data-workspace-id").unwrap_or_default();
        let current = if workspace == selected_workspace {
            "1"
        } else {
            "0"
        };
        let _ = el.set_attribute("data-current", current);
    }
}

async fn fetch_workspace_runtime(workspace_id: &str) -> Result<(String, u32, String), String> {
    let url =
        crate::config::build_masc_url(&format!("api/v1/trpg/state?workspace_id={}", workspace_id));
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

    let workspace = json.get("workspace").unwrap_or(&Value::Null);
    let state = json.get("state").unwrap_or(&Value::Null);

    let mut status = workspace
        .get("status")
        .and_then(Value::as_str)
        .or_else(|| state.get("status").and_then(Value::as_str))
        .unwrap_or("idle")
        .to_string();
    let turn = workspace
        .get("turn")
        .and_then(Value::as_u64)
        .or_else(|| state.get("turn").and_then(Value::as_u64))
        .unwrap_or(0) as u32;
    let phase = workspace
        .get("phase")
        .and_then(Value::as_str)
        .or_else(|| state.get("phase").and_then(Value::as_str))
        .unwrap_or("-")
        .to_string();

    if let Ok(operator_snapshot) = mcp_tool_call(
        "masc_operator_snapshot",
        json!({
            "view": "summary",
            "include_messages": false,
            "include_keepers": false,
        }),
    )
    .await
    {
        if operator_snapshot
            .get("workspace")
            .and_then(|workspace| workspace.get("paused"))
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            status = "paused".to_string();
        }
    }

    // Staleness detection: fallback override when state stream is stale.
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

pub(super) fn load_known_workspaces() -> Vec<String> {
    let raw = web_sys::window()
        .and_then(|w| w.local_storage().ok().flatten())
        .and_then(|storage| {
            storage
                .get_item(KNOWN_WORKSPACES_STORAGE_KEY)
                .ok()
                .flatten()
        })
        .unwrap_or_default();
    unique_non_empty(
        raw.split('\n')
            .filter_map(crate::config::sanitize_workspace_id)
            .collect::<Vec<_>>(),
    )
}

fn save_known_workspaces(workspaces: &[String]) {
    let value = workspaces.join("\n");
    if let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten()) {
        let _ = storage.set_item(KNOWN_WORKSPACES_STORAGE_KEY, &value);
    }
}

pub(super) fn candidate_workspace_ids() -> Vec<String> {
    unique_non_empty(
        std::iter::once(crate::config::current_workspace_id())
            .chain(std::iter::once(
                crate::config::DEFAULT_WORKSPACE_ID.to_string(),
            ))
            .chain(load_recent_workspaces().into_iter())
            .chain(load_known_workspaces().into_iter())
            .collect::<Vec<_>>(),
    )
}

fn load_workspace_hub_visible() -> bool {
    web_sys::window()
        .and_then(|w| w.local_storage().ok().flatten())
        .and_then(|storage| {
            storage
                .get_item(WORKSPACE_HUB_VISIBLE_STORAGE_KEY)
                .ok()
                .flatten()
        })
        .map(|value| matches!(value.trim(), "1" | "true" | "on"))
        .unwrap_or(true)
}

fn save_workspace_hub_visible(visible: bool) {
    if let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten()) {
        let _ = storage.set_item(
            WORKSPACE_HUB_VISIBLE_STORAGE_KEY,
            if visible { "1" } else { "0" },
        );
    }
}

fn load_workspace_hub_running_only() -> bool {
    web_sys::window()
        .and_then(|w| w.local_storage().ok().flatten())
        .and_then(|storage| {
            storage
                .get_item(WORKSPACE_HUB_RUNNING_ONLY_STORAGE_KEY)
                .ok()
                .flatten()
        })
        .map(|value| matches!(value.trim(), "1" | "true" | "on"))
        .unwrap_or(false)
}

fn save_workspace_hub_running_only(enabled: bool) {
    if let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten()) {
        let _ = storage.set_item(
            WORKSPACE_HUB_RUNNING_ONLY_STORAGE_KEY,
            if enabled { "1" } else { "0" },
        );
    }
}

fn sync_workspace_hub_top_offset(doc: &web_sys::Document) {
    let top_px = doc
        .get_element_by_id("top-bar")
        .and_then(|el| {
            el.dyn_ref::<web_sys::HtmlElement>()
                .map(|bar| bar.offset_height())
        })
        .map(|height| height.max(84))
        .unwrap_or(84);
    if let Some(hub) = doc
        .get_element_by_id("workspace-hub")
        .and_then(|el| el.dyn_into::<web_sys::HtmlElement>().ok())
    {
        let _ = hub
            .style()
            .set_property("--workspace-hub-top", &format!("{}px", top_px));
    }
}

fn set_workspace_hub_visible(doc: &web_sys::Document, visible: bool) {
    sync_workspace_hub_top_offset(doc);
    set_element_display(doc, "workspace-hub", if visible { "grid" } else { "none" });
    if let Some(toggle) = doc.get_element_by_id("workspace-hub-toggle") {
        let _ = toggle.set_attribute("aria-pressed", if visible { "true" } else { "false" });
        toggle.set_text_content(Some(if visible {
            "방 목록 닫기"
        } else {
            "방 목록"
        }));
    }
}

fn remember_known_workspaces(extra_workspaces: &[String]) {
    let mut workspaces = load_known_workspaces();
    for raw in extra_workspaces {
        let Some(workspace) = crate::config::sanitize_workspace_id(raw) else {
            continue;
        };
        if workspaces.iter().any(|existing| existing == &workspace) {
            continue;
        }
        workspaces.push(workspace);
    }
    workspaces = unique_non_empty(workspaces);
    if workspaces.len() > 64 {
        workspaces = workspaces.split_off(workspaces.len() - 64);
    }
    save_known_workspaces(&workspaces);
}

fn is_known_workspace_id(workspace_id: &str) -> bool {
    let Some(workspace) = crate::config::sanitize_workspace_id(workspace_id) else {
        return false;
    };
    if workspace.eq_ignore_ascii_case(crate::config::DEFAULT_WORKSPACE_ID) {
        return true;
    }
    let mut known = load_known_workspaces();
    known.extend(load_recent_workspaces());
    known.push(crate::config::current_workspace_id());
    known
        .iter()
        .any(|existing| existing.eq_ignore_ascii_case(&workspace))
}

fn confirm_unknown_workspace_switch(doc: &web_sys::Document, workspace_id: &str) -> bool {
    let workspace_label = workspace_display_label(workspace_id);
    let message = format!(
        "'{}' 방은 현재 목록에 없습니다.\n빈 방으로 이동합니다. (세션은 시작되지 않음)\n계속할까요?",
        workspace_label
    );
    let proceed = web_sys::window()
        .and_then(|window| window.confirm_with_message(&message).ok())
        .unwrap_or(true);
    if !proceed {
        if let Some(pill) = doc.get_element_by_id("workspace-status") {
            let current = crate::config::current_workspace_id();
            let current_label = workspace_display_label(&current);
            pill.set_text_content(Some(&format!("현재 게임: {} · 이동 취소", current_label)));
        }
    }
    proceed
}

fn inline_selector_workspaces(
    selected_workspace: &str,
    known_workspaces: &[String],
) -> Vec<String> {
    let is_generated = |workspace: &str| {
        let key = workspace.to_ascii_lowercase();
        key.starts_with("adventure-")
            || key.starts_with("workspace-current-")
            || key.starts_with("persist-")
    };

    let mut workspaces = Vec::with_capacity(known_workspaces.len() + 2);
    workspaces.push(selected_workspace.to_string());
    workspaces.push(crate::config::DEFAULT_WORKSPACE_ID.to_string());
    workspaces.extend(known_workspaces.iter().cloned());

    let deduped = unique_non_empty(workspaces);
    let mut prioritized = Vec::with_capacity(deduped.len());
    let mut generated = Vec::new();

    for workspace in deduped {
        if workspace == selected_workspace
            || workspace.eq_ignore_ascii_case(crate::config::DEFAULT_WORKSPACE_ID)
        {
            prioritized.push(workspace);
            continue;
        }
        if is_generated(&workspace) {
            generated.push(workspace);
        } else {
            prioritized.push(workspace);
        }
    }
    prioritized.extend(generated);
    if prioritized.len() > INLINE_SELECTOR_MAX_OPTIONS {
        prioritized.truncate(INLINE_SELECTOR_MAX_OPTIONS);
    }
    prioritized
}

pub(super) fn sync_workspace_controls(doc: &web_sys::Document, selected_workspace: &str) {
    let selected = crate::config::sanitize_workspace_id(selected_workspace)
        .unwrap_or_else(|| crate::config::DEFAULT_WORKSPACE_ID.to_string());
    let workspaces = inline_selector_workspaces(&selected, &load_recent_workspaces());
    sync_workspace_hub_top_offset(doc);

    if let Some(select) = doc
        .get_element_by_id("workspace-selector-inline")
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
    {
        let html = workspaces
            .iter()
            .map(|workspace| {
                let safe = html_escape(workspace);
                let label = html_escape(&workspace_display_label(workspace));
                format!(r#"<option value="{safe}">{label}</option>"#)
            })
            .collect::<Vec<_>>()
            .join("");
        select.set_inner_html(&html);
        select.set_value(&selected);
    }
    if let Some(input) = doc
        .get_element_by_id("workspace-input-inline")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        if input.value().trim().eq_ignore_ascii_case(&selected) {
            input.set_value("");
        }
    }
    if let Some(pill) = doc.get_element_by_id("workspace-status") {
        let lifecycle = TrpgLifecycleState::Loading;
        let selected_label = workspace_display_label(&selected);
        pill.set_text_content(Some(&format!(
            "현재 게임: {} · {}",
            selected_label,
            lifecycle.label_ko()
        )));
        let _ = pill.set_attribute("data-lifecycle", lifecycle.css_class());
        let _ = pill.set_attribute("title", lifecycle.help_text());
    }
    sync_workspace_hub_selection(doc, &selected);
}

fn apply_workspace_switch_from_ui(
    doc: &web_sys::Document,
    raw_workspace: &str,
    manual_input: bool,
) {
    let Some(workspace) = crate::config::sanitize_workspace_id(raw_workspace) else {
        log::warn!("Ignoring invalid workspace id from UI: {}", raw_workspace);
        return;
    };
    let unknown_workspace = !is_known_workspace_id(&workspace);
    if manual_input && unknown_workspace && !confirm_unknown_workspace_switch(doc, &workspace) {
        return;
    }

    remember_known_workspaces(std::slice::from_ref(&workspace));
    set_current_workspace_id(doc, &workspace);
    if unknown_workspace {
        if let Some(pill) = doc.get_element_by_id("workspace-status") {
            let workspace_label = workspace_display_label(&workspace);
            pill.set_text_content(Some(&format!(
                "현재 게임: {} · 빈 방(세션 없음, 새 게임 필요)",
                workspace_label
            )));
            let _ = pill.set_attribute("data-lifecycle", TrpgLifecycleState::Idle.css_class());
            let _ = pill.set_attribute(
                "title",
                "해당 방에 세션이 없을 수 있습니다. 새 게임에서 시작할 수 있습니다.",
            );
        }
    }
    if let Some(dashboard) = doc.get_element_by_id("dashboard") {
        let _ = dashboard.set_attribute("data-auto-round", "0");
    }
    render_auto_round_toggle(doc);
    crate::game::round_runner::set_auto_round_running(false);
    clear_trpg_dom(doc);
    sync_workspace_hub_selection(doc, &workspace);
    if let Some(input) = doc
        .get_element_by_id("workspace-input-inline")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_value("");
    }
    let doc_for_refresh = doc.clone();
    wasm_bindgen_futures::spawn_local(async move {
        if let Ok(rows) = refresh_actor_admin_list(&doc_for_refresh).await {
            actor_admin_set_status(
                &doc_for_refresh,
                &format!(
                    "workspace {} 액터 {}명",
                    actor_admin_workspace_id(),
                    rows.len()
                ),
                "status-ok",
            );
        }
    });
    let doc_for_workspaces = doc.clone();
    wasm_bindgen_futures::spawn_local(async move {
        if let Err(e) = refresh_workspaces_from_server(&doc_for_workspaces).await {
            log::warn!("workspace 목록 동기화 실패(방 이동 직후): {}", e);
        }
    });
    log::info!("Viewer workspace switched to {}", workspace);
}

pub(super) async fn refresh_workspaces_from_server(
    doc: &web_sys::Document,
) -> Result<Vec<WorkspaceSnapshot>, String> {
    let workspace_ids = candidate_workspace_ids();
    if workspace_ids.is_empty() {
        return Err("추적할 workspace 후보가 없습니다.".to_string());
    }

    let mut snapshots = workspace_ids
        .iter()
        .map(|workspace_id| WorkspaceSnapshot {
            id: workspace_id.clone(),
            status: "idle".to_string(),
            turn: 0,
            phase: "-".to_string(),
            agent_count: 0,
            task_count: 0,
        })
        .collect::<Vec<_>>();

    for row in &mut snapshots {
        match fetch_workspace_runtime(&row.id).await {
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

    remember_known_workspaces(&workspace_ids);
    let mut current = crate::config::current_workspace_id();
    if let Some(replacement) = select_workspace_for_ended_default(&current, &snapshots) {
        log::info!(
            "Current workspace {} is ended; auto-switching to {}",
            current,
            replacement
        );
        set_current_workspace_id(doc, &replacement);
        clear_trpg_dom(doc);
        current = replacement;
    }
    let ended_ids = snapshots
        .iter()
        .filter(|row| TrpgLifecycleState::from_status(&row.status) == TrpgLifecycleState::Ended)
        .map(|row| row.id.to_ascii_lowercase())
        .collect::<std::collections::HashSet<_>>();
    let mut recent_workspaces = load_recent_workspaces();
    recent_workspaces.retain(|workspace| {
        workspace.eq_ignore_ascii_case(&current)
            || !ended_ids.contains(&workspace.to_ascii_lowercase())
    });
    save_recent_workspaces(&recent_workspaces);
    sync_workspace_controls(doc, &current);
    render_workspace_hub(doc, &snapshots, &current);
    bind_workspace_hub_buttons(doc);
    let current_status = snapshots
        .iter()
        .find(|row| row.id == current)
        .map(|row| row.status.as_str())
        .unwrap_or("idle");

    // Auto-round is a gameplay convenience for active rounds only.
    // Keep it off in idle/ended/unavailable to avoid confusing "auto running"
    // signals when the workspace cannot actually advance.
    if TrpgLifecycleState::from_status(current_status) != TrpgLifecycleState::Running {
        if let Some(dashboard) = doc.get_element_by_id("dashboard") {
            let _ = dashboard.set_attribute("data-auto-round", "0");
        }
        render_auto_round_toggle(doc);
        crate::game::round_runner::set_auto_round_running(false);
    }

    sync_session_pause_buttons(doc, current_status);
    Ok(snapshots)
}

fn merge_workspace_snapshot(existing: &mut WorkspaceSnapshot, incoming: WorkspaceSnapshot) {
    if existing.status.trim().is_empty()
        || existing.status.eq_ignore_ascii_case("idle")
        || existing.status.eq_ignore_ascii_case("unknown")
    {
        if !incoming.status.trim().is_empty() {
            existing.status = incoming.status.clone();
        }
    }
    if incoming.turn >= existing.turn {
        existing.turn = incoming.turn;
        if !incoming.phase.trim().is_empty() {
            existing.phase = incoming.phase.clone();
        }
    } else if (existing.phase.trim().is_empty() || existing.phase.trim() == "-")
        && !incoming.phase.trim().is_empty()
    {
        existing.phase = incoming.phase.clone();
    }
    existing.agent_count = existing.agent_count.max(incoming.agent_count);
    existing.task_count = existing.task_count.max(incoming.task_count);
}

fn dedup_workspace_snapshots(rows: Vec<WorkspaceSnapshot>) -> Vec<WorkspaceSnapshot> {
    use std::collections::HashMap;

    let mut out: Vec<WorkspaceSnapshot> = Vec::new();
    let mut index_by_id: HashMap<String, usize> = HashMap::new();

    for mut row in rows {
        row.id = crate::config::sanitize_workspace_id(&row.id)
            .unwrap_or_else(|| row.id.trim().to_string());
        if row.id.is_empty() {
            continue;
        }
        let key = row.id.to_ascii_lowercase();
        if let Some(idx) = index_by_id.get(&key).copied() {
            if let Some(existing) = out.get_mut(idx) {
                merge_workspace_snapshot(existing, row);
            }
            continue;
        }
        let idx = out.len();
        index_by_id.insert(key, idx);
        out.push(row);
    }

    out
}

pub(super) fn bind_workspace_controls(doc: &web_sys::Document) {
    let Some(select_el) = doc.get_element_by_id("workspace-selector-inline") else {
        return;
    };
    let workspace_now = crate::config::current_workspace_id();
    sync_workspace_controls(doc, &workspace_now);
    set_workspace_hub_visible(doc, load_workspace_hub_visible());

    if select_el.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = select_el.set_attribute("data-bound", "1");

    let select_cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let selected = doc
            .get_element_by_id("workspace-selector-inline")
            .and_then(|el| {
                el.dyn_ref::<web_sys::HtmlSelectElement>()
                    .map(|s| s.value())
            })
            .unwrap_or_default();
        if selected.trim().is_empty() {
            return;
        }
        apply_workspace_switch_from_ui(&doc, &selected, false);
    }) as Box<dyn FnMut()>);
    let _ = select_el.dyn_ref::<web_sys::EventTarget>().map(|target| {
        target.add_event_listener_with_callback("change", select_cb.as_ref().unchecked_ref())
    });
    select_cb.forget();

    if let Some(apply_btn) = doc.get_element_by_id("workspace-apply-btn") {
        let apply_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            let typed = doc
                .get_element_by_id("workspace-input-inline")
                .and_then(|el| el.dyn_ref::<web_sys::HtmlInputElement>().map(|i| i.value()))
                .unwrap_or_default();
            apply_workspace_switch_from_ui(&doc, &typed, true);
        }) as Box<dyn FnMut()>);
        let _ = apply_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", apply_cb.as_ref().unchecked_ref())
        });
        apply_cb.forget();
    }

    if let Some(input_el) = doc.get_element_by_id("workspace-input-inline") {
        let key_cb = Closure::wrap(Box::new(move |event: web_sys::KeyboardEvent| {
            if event.key() != "Enter" {
                return;
            }
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            let typed = doc
                .get_element_by_id("workspace-input-inline")
                .and_then(|el| el.dyn_ref::<web_sys::HtmlInputElement>().map(|i| i.value()))
                .unwrap_or_default();
            apply_workspace_switch_from_ui(&doc, &typed, true);
        }) as Box<dyn FnMut(web_sys::KeyboardEvent)>);
        let _ = input_el.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("keydown", key_cb.as_ref().unchecked_ref())
        });
        key_cb.forget();
    }

    if let Some(refresh_btn) = doc.get_element_by_id("workspace-refresh-btn") {
        let refresh_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            if let Some(pill) = doc.get_element_by_id("workspace-status") {
                let current = crate::config::current_workspace_id();
                let current_label = workspace_display_label(&current);
                pill.set_text_content(Some(&format!(
                    "현재 게임: {} · 목록 불러오는 중...",
                    current_label
                )));
            }
            let doc_for_fetch = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                match refresh_workspaces_from_server(&doc_for_fetch).await {
                    Ok(workspaces) => {
                        let current = crate::config::current_workspace_id();
                        let ended_count = workspaces
                            .iter()
                            .filter(|row| {
                                TrpgLifecycleState::from_status(&row.status)
                                    == TrpgLifecycleState::Ended
                            })
                            .count();
                        let current_is_ended = workspaces
                            .iter()
                            .find(|row| row.id.eq_ignore_ascii_case(&current))
                            .map(|row| {
                                TrpgLifecycleState::from_status(&row.status)
                                    == TrpgLifecycleState::Ended
                            })
                            .unwrap_or(false);
                        let visible_count = workspaces.len().saturating_sub(ended_count)
                            + usize::from(current_is_ended);
                        if let Some(pill) = doc_for_fetch.get_element_by_id("workspace-status") {
                            let current_label = workspace_display_label(&current);
                            pill.set_text_content(Some(&format!(
                                "현재 게임: {} · 표시 {} / 전체 {}",
                                current_label,
                                visible_count,
                                workspaces.len()
                            )));
                        }
                    }
                    Err(e) => {
                        log::warn!("workspace 목록 새로고침 실패: {}", e);
                        let current = crate::config::current_workspace_id();
                        if let Some(pill) = doc_for_fetch.get_element_by_id("workspace-status") {
                            let current_label = workspace_display_label(&current);
                            pill.set_text_content(Some(&format!(
                                "현재 게임: {} · 목록 실패",
                                current_label
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

    if let Some(hub_toggle) = doc.get_element_by_id("workspace-hub-toggle") {
        let hub_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            let visible = doc
                .get_element_by_id("workspace-hub-toggle")
                .and_then(|el| el.get_attribute("aria-pressed"))
                .map(|v| v == "true")
                .unwrap_or(false);
            let next = !visible;
            set_workspace_hub_visible(&doc, next);
            save_workspace_hub_visible(next);
        }) as Box<dyn FnMut()>);
        let _ = hub_toggle.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", hub_cb.as_ref().unchecked_ref())
        });
        hub_cb.forget();
    }
}
