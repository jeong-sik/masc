//! Viewer mode state machine with JS↔Bevy interactivity bridge.
//!
//! Each mode represents a distinct visualization context within the MASC viewer.
//! Bevy's `States` derive gates system execution per mode — TRPG systems only
//! run in `ViewerMode::Trpg`, monitor systems only in `ViewerMode::Monitor`, etc.
//!
//! DOM click events (mode cards, back button) write to a shared `ModeTransitionBuffer`.
//! A Bevy `Update` system polls the buffer each frame and triggers `NextState::set()`.

use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use serde_json::{json, Value};

#[cfg(target_arch = "wasm32")]
use std::sync::{Arc, Mutex};

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;

#[cfg(target_arch = "wasm32")]
use crate::dom::escape::html_escape;
#[cfg(target_arch = "wasm32")]
use crate::game::lifecycle::TrpgLifecycleState;
use crate::game::state::ConnectionStatus;
#[cfg(target_arch = "wasm32")]
const VIEWER_LAST_MODE_STORAGE_KEY: &str = "masc.viewer.last_mode";
#[cfg(target_arch = "wasm32")]
const VIEWER_LAYOUT_PREFS_STORAGE_KEY: &str = "masc.viewer.layout.v2";

#[cfg(target_arch = "wasm32")]
#[derive(Clone, Copy, Debug)]
struct ViewLayoutPrefs {
    show_ops: bool,
    show_secondary: bool,
    show_tertiary: bool,
    show_bottom: bool,
}

#[cfg(target_arch = "wasm32")]
impl Default for ViewLayoutPrefs {
    fn default() -> Self {
        Self {
            show_ops: true,
            show_secondary: true,
            show_tertiary: true,
            // Default to map-first layout for TRPG readability.
            show_bottom: false,
        }
    }
}

/// Top-level viewer mode. Determines which plugins/systems are active
/// and which SSE endpoint the viewer connects to.
#[derive(States, Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ViewerMode {
    /// Mode selection screen. No SSE connection, no game state.
    #[default]
    Home,

    /// D&D 5e game session viewer (그림란드 연대기).
    /// Data source:
    /// - default: MASC `/api/v1/trpg/stream` JSON polling
    /// - optional: legacy TRPG Engine `/workspaces/:id/stream` SSE
    Trpg,

    /// Experiment visualization — Sankey diagrams, network graphs, A/B metrics.
    /// SSE: MASC `/sse?workspace=experiment`
    Experiment,

    /// System monitor — keeper metrics, agent health, heartbeat dashboard.
    /// SSE: MASC `/sse?workspace=monitor`
    Monitor,

    /// Social board feed — agent posts, comments, reactions.
    /// SSE: MASC `/sse?workspace=social`
    Social,
}

#[allow(dead_code)]
impl ViewerMode {
    /// Human-readable display name for UI rendering.
    /// Used by `poll_mode_transition` (wasm32 only).
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Home => "MASC Viewer",
            Self::Trpg => "그림란드 연대기",
            Self::Experiment => "Experiment Lab",
            Self::Monitor => "System Monitor",
            Self::Social => "Social Board",
        }
    }

    /// DOM panel element ID for MASC mode panels.
    /// Returns `None` for Home and Trpg (they use different layout).
    pub fn panel_id(&self) -> Option<&'static str> {
        match self {
            Self::Monitor => Some("monitor-panel"),
            Self::Social => Some("social-panel"),
            Self::Experiment => Some("experiment-panel"),
            _ => None,
        }
    }

    /// DOM status badge element ID for MASC mode panels.
    pub fn status_badge_id(&self) -> Option<&'static str> {
        match self {
            Self::Monitor => Some("monitor-status"),
            Self::Social => Some("social-status"),
            Self::Experiment => Some("experiment-status"),
            _ => None,
        }
    }

    /// CSS class name applied to the HTML body for mode-specific DOM styling.
    /// Used by `poll_mode_transition` (wasm32 only).
    pub fn css_class(&self) -> &'static str {
        match self {
            Self::Home => "mode-home",
            Self::Trpg => "mode-trpg",
            Self::Experiment => "mode-experiment",
            Self::Monitor => "mode-monitor",
            Self::Social => "mode-social",
        }
    }

    /// Parse from the HTML `data-mode` attribute value.
    /// Used by `bind_mode_cards` (wasm32 only).
    pub fn from_data_attr(s: &str) -> Option<ViewerMode> {
        match s {
            "trpg" => Some(Self::Trpg),
            "experiment" => Some(Self::Experiment),
            "monitor" => Some(Self::Monitor),
            "social" => Some(Self::Social),
            _ => None,
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn mode_storage_value(mode: ViewerMode) -> &'static str {
    match mode {
        ViewerMode::Home => "home",
        ViewerMode::Trpg => "trpg",
        ViewerMode::Experiment => "experiment",
        ViewerMode::Monitor => "monitor",
        ViewerMode::Social => "social",
    }
}

#[cfg(target_arch = "wasm32")]
fn parse_mode_storage_value(raw: &str) -> Option<ViewerMode> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "home" => Some(ViewerMode::Home),
        "trpg" => Some(ViewerMode::Trpg),
        "experiment" => Some(ViewerMode::Experiment),
        "monitor" => Some(ViewerMode::Monitor),
        "social" => Some(ViewerMode::Social),
        _ => None,
    }
}

#[cfg(target_arch = "wasm32")]
fn persist_last_mode(mode: ViewerMode) {
    if let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten()) {
        let _ = storage.set_item(VIEWER_LAST_MODE_STORAGE_KEY, mode_storage_value(mode));
    }
}

#[cfg(target_arch = "wasm32")]
fn load_last_mode() -> Option<ViewerMode> {
    web_sys::window()
        .and_then(|w| w.local_storage().ok().flatten())
        .and_then(|storage| {
            storage
                .get_item(VIEWER_LAST_MODE_STORAGE_KEY)
                .ok()
                .flatten()
        })
        .and_then(|raw| parse_mode_storage_value(&raw))
}

#[cfg(target_arch = "wasm32")]
fn mode_from_query() -> Option<ViewerMode> {
    let search = web_sys::window()
        .and_then(|w| w.location().search().ok())
        .unwrap_or_default();
    let query = search.trim_start_matches('?');
    for pair in query.split('&') {
        let mut chunks = pair.splitn(2, '=');
        let Some(key) = chunks.next() else { continue };
        if key != "mode" {
            continue;
        }
        let Some(value) = chunks.next() else { continue };
        if let Some(mode) = parse_mode_storage_value(value) {
            return Some(mode);
        }
    }
    None
}

#[cfg(target_arch = "wasm32")]
fn initial_mode_from_url_or_storage() -> Option<ViewerMode> {
    mode_from_query()
        .or_else(load_last_mode)
        .and_then(|mode| match mode {
            ViewerMode::Home => None,
            other => Some(other),
        })
}

#[cfg(target_arch = "wasm32")]
fn sync_url_for_mode(mode: ViewerMode) {
    let Some(win) = web_sys::window() else { return };
    let Ok(history) = win.history() else { return };

    let mode_value = mode_storage_value(mode);
    let mut params = vec![format!("mode={}", mode_value)];
    if mode == ViewerMode::Trpg {
        let workspace_id = crate::config::current_workspace_id();
        params.push(format!("workspace={}", workspace_id));
    }
    let query = format!("?{}", params.join("&"));
    let _ = history.replace_state_with_url(&wasm_bindgen::JsValue::NULL, "", Some(&query));
}

#[cfg(target_arch = "wasm32")]
fn load_view_layout_prefs() -> ViewLayoutPrefs {
    let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten()) else {
        return ViewLayoutPrefs::default();
    };
    let Ok(Some(raw)) = storage.get_item(VIEWER_LAYOUT_PREFS_STORAGE_KEY) else {
        return ViewLayoutPrefs::default();
    };
    let Ok(json) = serde_json::from_str::<Value>(&raw) else {
        return ViewLayoutPrefs::default();
    };
    let mut prefs = ViewLayoutPrefs::default();
    if let Some(v) = json.get("show_ops").and_then(Value::as_bool) {
        prefs.show_ops = v;
    }
    if let Some(v) = json.get("show_secondary").and_then(Value::as_bool) {
        prefs.show_secondary = v;
    }
    if let Some(v) = json.get("show_tertiary").and_then(Value::as_bool) {
        prefs.show_tertiary = v;
    }
    if let Some(v) = json.get("show_bottom").and_then(Value::as_bool) {
        prefs.show_bottom = v;
    }
    prefs
}

#[cfg(target_arch = "wasm32")]
fn save_view_layout_prefs(prefs: ViewLayoutPrefs) {
    let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten()) else {
        return;
    };
    let payload = json!({
        "show_ops": prefs.show_ops,
        "show_secondary": prefs.show_secondary,
        "show_tertiary": prefs.show_tertiary,
        "show_bottom": prefs.show_bottom,
    });
    let _ = storage.set_item(VIEWER_LAYOUT_PREFS_STORAGE_KEY, &payload.to_string());
}

// ─── Shared Buffer Resource ──────────────────

/// Holds pending mode transitions from JS click events.
/// The JS closure writes here; a Bevy Update system drains it.
#[derive(Resource, Default)]
pub struct ModeTransitionBuffer {
    #[cfg(target_arch = "wasm32")]
    pending: Arc<Mutex<Option<ViewerMode>>>,
    #[cfg(not(target_arch = "wasm32"))]
    _phantom: (),
}

// ─── Plugin ──────────────────────────────────

/// Plugin that registers the ViewerMode state and mode transition systems.
pub struct ModePlugin;

impl Plugin for ModePlugin {
    fn build(&self, app: &mut App) {
        app.init_state::<ViewerMode>()
            .init_resource::<ModeTransitionBuffer>()
            .add_systems(OnEnter(ViewerMode::Home), on_enter_home)
            .add_systems(OnExit(ViewerMode::Home), on_exit_home)
            .add_systems(OnEnter(ViewerMode::Trpg), enter_trpg)
            .add_systems(OnExit(ViewerMode::Trpg), exit_trpg)
            .add_systems(OnEnter(ViewerMode::Monitor), enter_masc_panel)
            .add_systems(OnExit(ViewerMode::Monitor), exit_masc_panel)
            .add_systems(OnEnter(ViewerMode::Social), enter_masc_panel)
            .add_systems(OnExit(ViewerMode::Social), exit_masc_panel)
            .add_systems(OnEnter(ViewerMode::Experiment), enter_masc_panel)
            .add_systems(OnExit(ViewerMode::Experiment), exit_masc_panel)
            .add_systems(
                Update,
                refresh_trpg_widget_status.run_if(in_state(ViewerMode::Trpg)),
            )
            .add_systems(Update, poll_mode_transition)
            .add_systems(Update, sync_masc_panel_connection_status);
    }
}

// ─── Home Enter/Exit ────────────────────────

/// Startup logic when entering Home mode: show home UI, bind click listeners.
fn on_enter_home(buffer: Res<ModeTransitionBuffer>) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        clear_trpg_dom(&doc);
        // Show home UI, hide dashboard
        if let Some(body) = doc.body() {
            body.set_class_name("mode-home");
        }
        set_element_display(&doc, "home-screen", "flex");
        set_element_display(&doc, "dashboard", "none");

        // Bind mode card clicks
        bind_mode_cards(&doc, &buffer.pending);

        // Bind back-to-home button
        bind_back_button(&doc, &buffer.pending);
        bind_debug_controls(&doc);
        bind_new_game_controls(&doc);

        // Hide loading screen once Bevy is initialized
        if let Some(loading) = doc.get_element_by_id("loading-screen") {
            if let Some(html_el) = loading.dyn_ref::<web_sys::HtmlElement>() {
                let _ = html_el.style().set_property("opacity", "0");
                let _ = html_el.style().set_property("pointer-events", "none");
            }
        }

        // Restore the last active mode once at startup so refresh returns to
        // the game view instead of forcing home re-entry.
        if let Some(body) = doc.body() {
            let restored_once = body
                .get_attribute("data-mode-restored")
                .map(|v| v == "1")
                .unwrap_or(false);
            if !restored_once {
                let _ = body.set_attribute("data-mode-restored", "1");
                if let Some(mode) = initial_mode_from_url_or_storage() {
                    if let Ok(mut pending) = buffer.pending.lock() {
                        *pending = Some(mode);
                    }
                }
            }
        }
    }

    // Suppress unused warning on native
    let _ = &buffer;
}

/// Cleanup when leaving Home mode (entering a visualization mode).
fn on_exit_home() {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        set_element_display(&doc, "home-screen", "none");
        set_element_display(&doc, "dashboard", "grid");
    }
}

fn enter_trpg() {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        set_element_display(&doc, "dashboard", "grid");
        set_element_display(&doc, "home-screen", "none");
        set_element_display(&doc, "new-game-panel", "none");
        clear_trpg_dom(&doc);
        bind_debug_controls(&doc);
        bind_view_options(&doc);
        bind_new_game_controls(&doc);
        let workspace = crate::config::current_workspace_id();
        set_current_workspace_id(&doc, &workspace);
        bind_workspace_controls(&doc);
        bind_auto_round_toggle(&doc);
        bind_session_pause_controls(&doc);
        crate::game::round_runner::set_auto_round_running(auto_round_enabled_from_dom(&doc));

        if let Some(pill) = doc.get_element_by_id("workspace-status") {
            pill.set_text_content(Some(&format!(
                "현재 게임: {} · 목록 불러오는 중...",
                workspace
            )));
        }
        let doc_for_workspaces = doc.clone();
        wasm_bindgen_futures::spawn_local(async move {
            match refresh_workspaces_from_server(&doc_for_workspaces).await {
                Ok(workspaces) => {
                    let workspace_now = crate::config::current_workspace_id();
                    let ended_count = workspaces
                        .iter()
                        .filter(|row| {
                            TrpgLifecycleState::from_status(&row.status)
                                == TrpgLifecycleState::Ended
                        })
                        .count();
                    let current_is_ended = workspaces
                        .iter()
                        .find(|row| row.id.eq_ignore_ascii_case(&workspace_now))
                        .map(|row| {
                            TrpgLifecycleState::from_status(&row.status)
                                == TrpgLifecycleState::Ended
                        })
                        .unwrap_or(false);
                    let visible_count = workspaces.len().saturating_sub(ended_count)
                        + usize::from(current_is_ended);
                    if let Some(pill) = doc_for_workspaces.get_element_by_id("workspace-status") {
                        pill.set_text_content(Some(&format!(
                            "현재 게임: {} · 표시 {} / 전체 {}",
                            workspace_now,
                            visible_count,
                            workspaces.len()
                        )));
                    }
                }
                Err(e) => {
                    log::warn!("workspace 목록 로딩 실패: {}", e);
                    let workspace_now = crate::config::current_workspace_id();
                    if let Some(pill) = doc_for_workspaces.get_element_by_id("workspace-status") {
                        pill.set_text_content(Some(&format!(
                            "현재 게임: {} · 목록 실패",
                            workspace_now
                        )));
                    }
                }
            }
        });
    }
}

#[cfg(target_arch = "wasm32")]
fn bind_auto_round_toggle(doc: &web_sys::Document) {
    if let Some(dashboard) = doc.get_element_by_id("dashboard") {
        if dashboard.get_attribute("data-auto-round").is_none() {
            let _ = dashboard.set_attribute("data-auto-round", "0");
        }
    }
    render_auto_round_toggle(doc);

    let Some(button) = doc.get_element_by_id("auto-round-toggle") else {
        return;
    };
    if button.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = button.set_attribute("data-bound", "1");

    let doc_clone = doc.clone();
    let cb = Closure::wrap(Box::new(move || {
        // Toggling auto-round is explicit user activity.
        crate::game::round_runner::record_user_activity();

        let next = !auto_round_enabled_from_dom(&doc_clone);
        if let Some(dashboard) = doc_clone.get_element_by_id("dashboard") {
            let _ = dashboard.set_attribute("data-auto-round", if next { "1" } else { "0" });
        }
        render_auto_round_toggle(&doc_clone);
        crate::game::round_runner::set_auto_round_running(next);
    }) as Box<dyn FnMut()>);

    let _ = button.dyn_ref::<web_sys::EventTarget>().map(|target| {
        target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
    });
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
const SESSION_CONTROL_BADGE_CHAR_LIMIT: usize = 120;

#[cfg(target_arch = "wasm32")]
fn collapse_inline_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(target_arch = "wasm32")]
fn truncate_status_text(text: &str, limit: usize) -> String {
    if text.chars().count() <= limit {
        return text.to_string();
    }
    if limit <= 3 {
        return "...".to_string();
    }
    let mut out = text.chars().take(limit - 3).collect::<String>();
    out.push_str("...");
    out
}

#[cfg(target_arch = "wasm32")]
fn summarize_session_control_payload(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        if let Some(message) = value.get("message").and_then(Value::as_str) {
            let collapsed = collapse_inline_whitespace(message);
            if !collapsed.is_empty() {
                return collapsed;
            }
        }

        let ok = value.get("ok").and_then(Value::as_bool);
        let workspace_id = value
            .get("workspace_id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(|v| format!("workspace {v}"));
        let phase = value
            .get("phase")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(|v| format!("phase {v}"));
        let turn_after = value
            .get("turn_after")
            .and_then(Value::as_i64)
            .map(|turn| format!("turn {turn}"));
        let statuses = value
            .get("statuses")
            .and_then(Value::as_array)
            .map(|rows| format!("actors {}", rows.len()));

        let mut parts = Vec::new();
        if let Some(workspace) = workspace_id {
            parts.push(workspace);
        }
        if let Some(phase) = phase {
            parts.push(phase);
        }
        if let Some(turn) = turn_after {
            parts.push(turn);
        }
        if let Some(statuses) = statuses {
            parts.push(statuses);
        }

        if ok == Some(true) {
            if parts.is_empty() {
                return "ok".to_string();
            }
            return parts.join(" | ");
        }
    }

    collapse_inline_whitespace(trimmed)
}

#[cfg(target_arch = "wasm32")]
fn set_session_control_status(doc: &web_sys::Document, text: &str, tone: &str) {
    let Some(el) = doc.get_element_by_id("session-control-status") else {
        return;
    };
    let full_text = {
        let collapsed = collapse_inline_whitespace(text);
        if collapsed.is_empty() {
            "세션 제어 대기".to_string()
        } else {
            collapsed
        }
    };
    let display_text = truncate_status_text(&full_text, SESSION_CONTROL_BADGE_CHAR_LIMIT);
    let class_name = if tone.trim().is_empty() {
        "widget-pill".to_string()
    } else {
        format!("widget-pill {}", tone.trim())
    };
    let unchanged = el.text_content().as_deref() == Some(display_text.as_str())
        && el.get_attribute("class").as_deref() == Some(class_name.as_str())
        && el.get_attribute("title").as_deref() == Some(full_text.as_str());
    if unchanged {
        return;
    }
    el.set_text_content(Some(&display_text));
    let _ = el.set_attribute("class", &class_name);
    let _ = el.set_attribute("title", &full_text);
}

#[cfg(target_arch = "wasm32")]
fn set_session_control_busy(doc: &web_sys::Document, busy: bool) {
    for id in ["session-pause-btn", "session-resume-btn"] {
        let Some(btn) = doc
            .get_element_by_id(id)
            .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
        else {
            continue;
        };
        btn.set_disabled(busy);
        if busy {
            let _ = btn.set_attribute("aria-busy", "true");
        } else {
            let _ = btn.remove_attribute("aria-busy");
        }
    }
}

#[cfg(target_arch = "wasm32")]
async fn execute_workspace_operator_action(
    action_type: &str,
    payload: Value,
) -> Result<Option<Value>, String> {
    let action = mcp_tool_call(
        "masc_operator_action",
        json!({
            "action_type": action_type,
            "target_type": "workspace",
            "payload": payload,
        }),
    )
    .await?;
    if !action
        .get("confirm_required")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return Ok(Some(action));
    }

    let confirm_token = action
        .get("confirm_token")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|token| !token.is_empty())
        .ok_or_else(|| {
            "operator action requires confirmation but returned no confirm token".to_string()
        })?;
    let preview = action
        .get("preview")
        .map(Value::to_string)
        .unwrap_or_else(|| "Pause namespace automation?".to_string());
    let window = web_sys::window().ok_or_else(|| "window unavailable".to_string())?;
    let approved = window
        .confirm_with_message(&preview)
        .map_err(|e| format!("확인 다이얼로그 실패: {:?}", e))?;
    let confirmation = mcp_tool_call(
        "masc_operator_confirm",
        json!({
            "confirm_token": confirm_token,
            "decision": if approved { "confirm" } else { "deny" },
        }),
    )
    .await?;
    if approved {
        Ok(Some(confirmation))
    } else {
        Ok(None)
    }
}

#[cfg(target_arch = "wasm32")]
fn bind_session_pause_controls(doc: &web_sys::Document) {
    set_session_control_status(doc, "세션 제어 대기", "");

    if let Some(pause_btn) = doc.get_element_by_id("session-pause-btn") {
        if pause_btn.get_attribute("data-bound").as_deref() != Some("1") {
            let _ = pause_btn.set_attribute("data-bound", "1");
            let doc_for_pause = doc.clone();
            let cb = Closure::wrap(Box::new(move || {
                set_session_control_busy(&doc_for_pause, true);
                set_session_control_status(&doc_for_pause, "세션 멈춤 요청 중...", "status-info");

                let doc_async = doc_for_pause.clone();
                wasm_bindgen_futures::spawn_local(async move {
                    match execute_workspace_operator_action(
                        "namespace_pause",
                        json!({ "reason": "viewer trpg manual pause" }),
                    )
                    .await
                    {
                        Ok(Some(raw)) => {
                            if let Some(dashboard) = doc_async.get_element_by_id("dashboard") {
                                let _ = dashboard.set_attribute("data-auto-round", "0");
                            }
                            render_auto_round_toggle(&doc_async);
                            crate::game::round_runner::set_auto_round_running(false);
                            let detail = summarize_session_control_payload(&raw.to_string());
                            let status = if detail.is_empty() {
                                "세션 멈춤 완료".to_string()
                            } else {
                                format!("세션 멈춤 완료: {}", detail)
                            };
                            set_session_control_status(&doc_async, &status, "status-warn");
                            let doc_for_refresh = doc_async.clone();
                            wasm_bindgen_futures::spawn_local(async move {
                                let _ = refresh_workspaces_from_server(&doc_for_refresh).await;
                            });
                        }
                        Ok(None) => {
                            set_session_control_status(
                                &doc_async,
                                "세션 멈춤 요청을 거부했습니다",
                                "status-info",
                            );
                        }
                        Err(err) => {
                            set_session_control_status(
                                &doc_async,
                                &format!("세션 멈춤 실패: {}", err),
                                "status-error",
                            );
                        }
                    }
                    set_session_control_busy(&doc_async, false);
                });
            }) as Box<dyn FnMut()>);
            let _ = pause_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
                target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
            });
            cb.forget();
        }
    }

    if let Some(resume_btn) = doc.get_element_by_id("session-resume-btn") {
        if resume_btn.get_attribute("data-bound").as_deref() != Some("1") {
            let _ = resume_btn.set_attribute("data-bound", "1");
            let doc_for_resume = doc.clone();
            let cb = Closure::wrap(Box::new(move || {
                set_session_control_busy(&doc_for_resume, true);
                set_session_control_status(&doc_for_resume, "세션 재개 요청 중...", "status-info");

                let doc_async = doc_for_resume.clone();
                wasm_bindgen_futures::spawn_local(async move {
                    match execute_workspace_operator_action("namespace_resume", json!({})).await {
                        Ok(Some(raw)) => {
                            let detail = summarize_session_control_payload(&raw.to_string());
                            let status = if detail.is_empty() {
                                "세션 재개 완료".to_string()
                            } else {
                                format!("세션 재개 완료: {}", detail)
                            };
                            set_session_control_status(&doc_async, &status, "status-ok");
                            let doc_for_refresh = doc_async.clone();
                            wasm_bindgen_futures::spawn_local(async move {
                                let _ = refresh_workspaces_from_server(&doc_for_refresh).await;
                            });
                        }
                        Ok(None) => {
                            set_session_control_status(
                                &doc_async,
                                "세션 재개 요청을 거부했습니다",
                                "status-info",
                            );
                        }
                        Err(err) => {
                            set_session_control_status(
                                &doc_async,
                                &format!("세션 재개 실패: {}", err),
                                "status-error",
                            );
                        }
                    }
                    set_session_control_busy(&doc_async, false);
                });
            }) as Box<dyn FnMut()>);
            let _ = resume_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
                target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
            });
            cb.forget();
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn sync_session_pause_buttons(doc: &web_sys::Document, workspace_status: &str) {
    let lifecycle = TrpgLifecycleState::from_status(workspace_status);
    let (pause_disabled, resume_disabled, title, status_text, status_tone) = match lifecycle {
        TrpgLifecycleState::Running => (
            false,
            true,
            "세션이 진행 중입니다.",
            "세션 진행 중입니다.",
            "status-ok",
        ),
        TrpgLifecycleState::Idle => (
            false,
            true,
            "세션이 대기 상태입니다. 필요 시 멈춤 가능합니다.",
            "세션 시작 전 대기 상태입니다. 새 게임에서 시작하세요.",
            "status-info",
        ),
        TrpgLifecycleState::Stopped => (
            true,
            false,
            "세션이 멈춤 상태입니다.",
            "세션이 멈춰 있습니다. 재개 버튼으로 계속 진행할 수 있습니다.",
            "status-warn",
        ),
        TrpgLifecycleState::Ended => (
            true,
            true,
            "종료된 세션은 재개할 수 없습니다.",
            "세션이 종료되었습니다. 새 게임 버튼으로 다시 시작하세요.",
            "status-info",
        ),
        TrpgLifecycleState::Unavailable => (
            true,
            true,
            "엔진 연결 오류 상태입니다.",
            "세션 상태를 가져오지 못했습니다. 엔진/키퍼 연결을 확인하세요.",
            "status-error",
        ),
        _ => (
            true,
            true,
            "세션 시작 후 제어할 수 있습니다.",
            "세션 상태 동기화 중입니다.",
            "status-info",
        ),
    };

    let mut is_busy = false;
    if let Some(btn) = doc
        .get_element_by_id("session-pause-btn")
        .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
    {
        let busy = btn.get_attribute("aria-busy").as_deref() == Some("true");
        if !busy {
            btn.set_disabled(pause_disabled);
        }
        is_busy = is_busy || busy;
        btn.set_title(title);
    }
    if let Some(btn) = doc
        .get_element_by_id("session-resume-btn")
        .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
    {
        let busy = btn.get_attribute("aria-busy").as_deref() == Some("true");
        if !busy {
            btn.set_disabled(resume_disabled);
        }
        is_busy = is_busy || busy;
        btn.set_title(title);
    }

    if !is_busy {
        set_session_control_status(doc, status_text, status_tone);
    }
}

#[cfg(target_arch = "wasm32")]
fn auto_round_enabled_from_dom(doc: &web_sys::Document) -> bool {
    let value = doc
        .get_element_by_id("dashboard")
        .and_then(|el| el.get_attribute("data-auto-round"))
        .unwrap_or_else(|| "0".to_string())
        .to_ascii_lowercase();
    matches!(value.as_str(), "1" | "true" | "on")
}

#[cfg(target_arch = "wasm32")]
fn render_auto_round_toggle(doc: &web_sys::Document) {
    let enabled = auto_round_enabled_from_dom(doc);
    if let Some(button) = doc.get_element_by_id("auto-round-toggle") {
        button.set_text_content(Some(if enabled {
            "자동 진행: ON"
        } else {
            "자동 진행: OFF"
        }));
        let _ = button.set_attribute("aria-pressed", if enabled { "true" } else { "false" });
        let _ = button.set_attribute(
            "title",
            if enabled {
                "AI 턴 자동 진행을 멈춥니다"
            } else {
                "AI 턴 자동 진행을 시작합니다"
            },
        );
    }
    if let Some(ops) = doc.get_element_by_id("ops-control-state") {
        ops.set_text_content(Some(if enabled { "auto-run" } else { "manual" }));
    }
}

fn exit_trpg() {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        set_element_display(&doc, "new-game-panel", "none");
        if let Some(toggle) = doc.get_element_by_id("view-options-toggle") {
            let _ = toggle.set_attribute("aria-pressed", "false");
            toggle.set_text_content(Some("화면 옵션"));
        }
        if let Some(popover) = doc.get_element_by_id("view-options-popover") {
            if let Some(el) = popover.dyn_ref::<web_sys::HtmlElement>() {
                let _ = el.style().set_property("display", "none");
            }
        }
    }
}

// ─── Mode Transition Polling ─────────────────

/// Polls the shared buffer each frame. When a mode card is clicked,
/// applies the transition via Bevy's state machine.
fn poll_mode_transition(
    buffer: Res<ModeTransitionBuffer>,
    current: Res<State<ViewerMode>>,
    mut next: ResMut<NextState<ViewerMode>>,
) {
    #[cfg(target_arch = "wasm32")]
    {
        let requested = {
            let Ok(mut buf) = buffer.pending.lock() else {
                return;
            };
            buf.take()
        };

        if let Some(mode) = requested {
            if *current.get() != mode {
                log::info!("Mode transition: {:?} → {:?}", current.get(), mode);

                // Set body CSS class for mode-specific styling
                if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
                    if let Some(body) = doc.body() {
                        body.set_class_name(mode.css_class());
                    }
                    // Update mode title in dashboard header
                    if let Some(el) = doc.get_element_by_id("mode-title") {
                        el.set_text_content(Some(mode.display_name()));
                    }
                }

                persist_last_mode(mode);
                sync_url_for_mode(mode);

                next.set(mode);
            }
        }
    }

    // Suppress unused warnings on native
    let _ = (&buffer, &current, &mut next);
}

// ─── JS Event Binding ────────────────────────

/// Binds click handlers to all `.mode-card[data-mode]` buttons.
/// Each click writes the target ViewerMode into the shared buffer.
#[cfg(target_arch = "wasm32")]
fn bind_mode_cards(doc: &web_sys::Document, pending: &Arc<Mutex<Option<ViewerMode>>>) {
    // Guard: only bind once to prevent closure accumulation on repeated home entries
    if let Some(container) = doc.get_element_by_id("mode-cards") {
        if container.get_attribute("data-bound").as_deref() == Some("1") {
            return;
        }
        let _ = container.set_attribute("data-bound", "1");
    }

    let cards = doc.query_selector_all(".mode-card[data-mode]");
    let Ok(cards) = cards else { return };

    for i in 0..cards.length() {
        let Some(node) = cards.item(i) else { continue };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };

        let Some(mode_attr) = el.get_attribute("data-mode") else {
            continue;
        };
        let Some(mode) = ViewerMode::from_data_attr(&mode_attr) else {
            continue;
        };

        let buf = pending.clone();
        let cb = Closure::wrap(Box::new(move || {
            if let Ok(mut guard) = buf.lock() {
                *guard = Some(mode);
            }
        }) as Box<dyn FnMut()>);

        let _ = el.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
        });

        cb.forget(); // Lives for app lifetime
    }
}

/// Binds the `#back-to-home` button to transition back to Home.
#[cfg(target_arch = "wasm32")]
fn bind_back_button(doc: &web_sys::Document, pending: &Arc<Mutex<Option<ViewerMode>>>) {
    let Some(btn) = doc.get_element_by_id("back-to-home") else {
        return;
    };
    // Guard: only bind once
    if btn.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = btn.set_attribute("data-bound", "1");

    let buf = pending.clone();
    let cb = Closure::wrap(Box::new(move || {
        if let Ok(mut guard) = buf.lock() {
            *guard = Some(ViewerMode::Home);
        }
    }) as Box<dyn FnMut()>);

    let _ = btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
        target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
    });

    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn apply_debug_visibility_in_dom(doc: &web_sys::Document, enabled: bool) {
    let Ok(entries) =
        doc.query_selector_all("#narrative-log .narrative-entry[data-debug-entry=\"1\"]")
    else {
        return;
    };

    for i in 0..entries.length() {
        let Some(node) = entries.item(i) else {
            continue;
        };
        let Some(el) = node.dyn_ref::<web_sys::HtmlElement>() else {
            continue;
        };
        let _ = el
            .style()
            .set_property("display", if enabled { "block" } else { "none" });
    }
}

#[cfg(target_arch = "wasm32")]
fn set_debug_state(doc: &web_sys::Document, enabled: bool) {
    if let Some(dashboard) = doc.get_element_by_id("dashboard") {
        let _ = dashboard.set_attribute("data-debug", if enabled { "on" } else { "off" });
    }
    if let Some(toggle) = doc.get_element_by_id("debug-log-toggle") {
        toggle.set_text_content(Some(if enabled { "Debug ON" } else { "Debug" }));
        let _ = toggle.set_attribute("aria-pressed", if enabled { "true" } else { "false" });
    }
    if let Some(status) = doc.get_element_by_id("debug-log-status") {
        status.set_text_content(Some(if enabled { "DEBUG" } else { "" }));
    }
    apply_debug_visibility_in_dom(doc, enabled);
}

#[cfg(target_arch = "wasm32")]
fn bind_debug_controls(doc: &web_sys::Document) {
    let Some(toggle) = doc.get_element_by_id("debug-log-toggle") else {
        return;
    };
    if toggle.get_attribute("data-bound").as_deref() == Some("1") {
        bind_dedup_status_toggle(doc);
        return;
    }
    let _ = toggle.set_attribute("data-bound", "1");
    set_debug_state(doc, false);

    let cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let enabled = doc
            .get_element_by_id("dashboard")
            .and_then(|el| el.get_attribute("data-debug"))
            .map(|v| v != "off")
            .unwrap_or(true);
        set_debug_state(&doc, !enabled);
    }) as Box<dyn FnMut()>);

    let _ = toggle.dyn_ref::<web_sys::EventTarget>().map(|target| {
        target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
    });

    cb.forget();
    bind_dedup_status_toggle(doc);
}

#[cfg(target_arch = "wasm32")]
fn apply_view_layout_prefs(doc: &web_sys::Document, prefs: ViewLayoutPrefs) {
    let Some(dashboard) = doc.get_element_by_id("dashboard") else {
        return;
    };
    let _ = dashboard.set_attribute("data-show-ops", if prefs.show_ops { "1" } else { "0" });
    let _ = dashboard.set_attribute(
        "data-show-secondary",
        if prefs.show_secondary { "1" } else { "0" },
    );
    let _ = dashboard.set_attribute(
        "data-show-tertiary",
        if prefs.show_tertiary { "1" } else { "0" },
    );
    let _ = dashboard.set_attribute(
        "data-show-bottom",
        if prefs.show_bottom { "1" } else { "0" },
    );

    if let Some(input) = doc
        .get_element_by_id("opt-show-ops")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_checked(prefs.show_ops);
    }
    if let Some(input) = doc
        .get_element_by_id("opt-show-secondary")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_checked(prefs.show_secondary);
    }
    if let Some(input) = doc
        .get_element_by_id("opt-show-tertiary")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_checked(prefs.show_tertiary);
    }
    if let Some(input) = doc
        .get_element_by_id("opt-show-bottom")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_checked(prefs.show_bottom);
    }
}

#[cfg(target_arch = "wasm32")]
fn read_view_layout_prefs_from_dom(doc: &web_sys::Document) -> ViewLayoutPrefs {
    let mut prefs = ViewLayoutPrefs::default();
    if let Some(input) = doc
        .get_element_by_id("opt-show-ops")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        prefs.show_ops = input.checked();
    }
    if let Some(input) = doc
        .get_element_by_id("opt-show-secondary")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        prefs.show_secondary = input.checked();
    }
    if let Some(input) = doc
        .get_element_by_id("opt-show-tertiary")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        prefs.show_tertiary = input.checked();
    }
    if let Some(input) = doc
        .get_element_by_id("opt-show-bottom")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        prefs.show_bottom = input.checked();
    }
    prefs
}

#[cfg(target_arch = "wasm32")]
fn bind_view_options(doc: &web_sys::Document) {
    apply_view_layout_prefs(doc, load_view_layout_prefs());

    if let Some(toggle) = doc.get_element_by_id("view-options-toggle") {
        if toggle.get_attribute("data-bound").as_deref() != Some("1") {
            let _ = toggle.set_attribute("data-bound", "1");
            let cb = Closure::wrap(Box::new(move || {
                let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                    return;
                };
                let expanded = doc
                    .get_element_by_id("view-options-toggle")
                    .and_then(|el| el.get_attribute("aria-pressed"))
                    .map(|v| v == "true")
                    .unwrap_or(false);
                let next = !expanded;
                if let Some(btn) = doc.get_element_by_id("view-options-toggle") {
                    let _ = btn.set_attribute("aria-pressed", if next { "true" } else { "false" });
                    btn.set_text_content(Some(if next {
                        "화면 옵션 ON"
                    } else {
                        "화면 옵션"
                    }));
                }
                if let Some(popover) = doc.get_element_by_id("view-options-popover") {
                    if let Some(el) = popover.dyn_ref::<web_sys::HtmlElement>() {
                        let _ = el
                            .style()
                            .set_property("display", if next { "grid" } else { "none" });
                    }
                }
            }) as Box<dyn FnMut()>);
            let _ = toggle.dyn_ref::<web_sys::EventTarget>().map(|target| {
                target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
            });
            cb.forget();
        }
    }

    for input_id in [
        "opt-show-ops",
        "opt-show-secondary",
        "opt-show-tertiary",
        "opt-show-bottom",
    ] {
        let Some(input) = doc
            .get_element_by_id(input_id)
            .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
        else {
            continue;
        };
        if input.get_attribute("data-bound").as_deref() == Some("1") {
            continue;
        }
        let _ = input.set_attribute("data-bound", "1");
        let cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            let prefs = read_view_layout_prefs_from_dom(&doc);
            apply_view_layout_prefs(&doc, prefs);
            save_view_layout_prefs(prefs);
        }) as Box<dyn FnMut()>);
        let _ = input.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("change", cb.as_ref().unchecked_ref())
        });
        cb.forget();
    }
}

#[cfg(target_arch = "wasm32")]
fn dedup_sample_list(doc: &web_sys::Document, attr: &str) -> String {
    let Some(dashboard) = doc.get_element_by_id("dashboard") else {
        return "<li>(없음)</li>".to_string();
    };
    let raw = dashboard.get_attribute(attr).unwrap_or_default();
    let rows = raw
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(html_escape)
        .collect::<Vec<_>>();
    if rows.is_empty() {
        return "<li>(없음)</li>".to_string();
    }
    rows.iter()
        .rev()
        .take(5)
        .map(|line| format!("<li>{}</li>", line))
        .collect::<Vec<_>>()
        .join("")
}

#[cfg(target_arch = "wasm32")]
pub(super) fn render_dedup_popover(doc: &web_sys::Document) {
    let Some(popover) = doc.get_element_by_id("dedup-popover") else {
        return;
    };
    let stream = dedup_sample_list(doc, "data-dedup-samples-stream");
    let narrative = dedup_sample_list(doc, "data-dedup-samples-narrative");
    let history = dedup_sample_list(doc, "data-dedup-samples-history");
    let html = format!(
        concat!(
            "<h4>Dedup 최근 스킵 샘플</h4>",
            "<div class=\"dedup-block\"><div class=\"dedup-label\">Stream</div><ul>{}</ul></div>",
            "<div class=\"dedup-block\"><div class=\"dedup-label\">Narrative</div><ul>{}</ul></div>",
            "<div class=\"dedup-block\"><div class=\"dedup-label\">History</div><ul>{}</ul></div>"
        ),
        stream, narrative, history
    );
    popover.set_inner_html(&html);
}

#[cfg(target_arch = "wasm32")]
fn bind_dedup_status_toggle(doc: &web_sys::Document) {
    let Some(btn) = doc.get_element_by_id("dedup-status") else {
        return;
    };
    if btn.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = btn.set_attribute("data-bound", "1");

    let cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let expanded = doc
            .get_element_by_id("dedup-status")
            .and_then(|el| el.get_attribute("aria-expanded"))
            .map(|v| v == "true")
            .unwrap_or(false);
        let next = !expanded;
        if let Some(button) = doc.get_element_by_id("dedup-status") {
            let _ = button.set_attribute("aria-expanded", if next { "true" } else { "false" });
        }
        if let Some(popover) = doc.get_element_by_id("dedup-popover") {
            if next {
                render_dedup_popover(&doc);
                if let Some(el) = popover.dyn_ref::<web_sys::HtmlElement>() {
                    let _ = el.style().set_property("display", "block");
                }
            } else if let Some(el) = popover.dyn_ref::<web_sys::HtmlElement>() {
                let _ = el.style().set_property("display", "none");
            }
        }
    }) as Box<dyn FnMut()>);

    let _ = btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
        target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
    });
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
pub(super) fn generate_workspace_id() -> String {
    let millis = js_sys::Date::now() as i64;
    let rand = (js_sys::Math::random() * 1000.0).floor() as i64;
    format!("adventure-{}-{:03}", millis, rand)
}

#[cfg(target_arch = "wasm32")]
pub(super) fn set_new_game_status(doc: &web_sys::Document, message: &str) {
    if let Some(el) = doc.get_element_by_id("new-game-status") {
        let escaped = html_escape(message);
        if el.inner_html() == escaped {
            return;
        }
        el.set_inner_html(&escaped);
    }
}

#[cfg(target_arch = "wasm32")]
pub(super) fn set_new_game_preflight_status(doc: &web_sys::Document, message: &str) {
    if let Some(el) = doc.get_element_by_id("new-game-preflight") {
        el.set_inner_html(&format!(
            "<span class=\"preflight-muted\">{}</span>",
            html_escape(message)
        ));
    }
}

#[cfg(target_arch = "wasm32")]
fn set_new_game_preflight_rows(doc: &web_sys::Document, rows: &[transport_classify::PreflightRow]) {
    if let Some(el) = doc.get_element_by_id("new-game-preflight") {
        let html = rows
            .iter()
            .map(|row| {
                let state_text = if row.ok { "OK" } else { "FAIL" };
                let state_class = if row.ok {
                    "preflight-state preflight-ok"
                } else {
                    "preflight-state preflight-fail"
                };
                let hint_html = match &row.hint {
                    Some(h) if !row.ok => format!(
                        "<div class=\"preflight-hint\">{}</div>",
                        html_escape(h)
                    ),
                    _ => String::new(),
                };
                format!(
                    "<div class=\"preflight-row\"><span class=\"{state_class}\">{state_text}</span><span>{label}: {detail}</span>{hint_html}</div>",
                    state_class = state_class,
                    state_text = state_text,
                    label = html_escape(&row.label),
                    detail = html_escape(&row.detail),
                    hint_html = hint_html,
                )
            })
            .collect::<Vec<_>>()
            .join("");
        el.set_inner_html(&html);
    }
}

#[cfg(target_arch = "wasm32")]
pub(super) fn set_current_workspace_id(doc: &web_sys::Document, workspace_id: &str) {
    crate::config::set_current_workspace_id(workspace_id);
    let workspace = crate::config::current_workspace_id();
    if let Some(dashboard) = doc.get_element_by_id("dashboard") {
        let _ = dashboard.set_attribute("data-workspace-id", &workspace);
    }
    remember_recent_workspace(&workspace);
    sync_workspace_controls(doc, &workspace);
    refresh_trpg_ops_snapshots(doc);
}

#[cfg(target_arch = "wasm32")]
pub(super) fn clear_trpg_dom(doc: &web_sys::Document) {
    if let Some(dashboard) = doc.get_element_by_id("dashboard") {
        let _ = dashboard.remove_attribute("data-focus-workspace");
        let _ = dashboard.remove_attribute("data-focus-turn");
        let _ = dashboard.remove_attribute("data-focus-kind");
    }
    if let Some(el) = doc.get_element_by_id("narrative-log") {
        el.set_inner_html("");
    }
    if let Some(el) = doc.get_element_by_id("dice-log") {
        el.set_inner_html("");
    }
    if let Some(el) = doc.get_element_by_id("session-history") {
        el.set_inner_html("");
    }
    if let Some(el) = doc.get_element_by_id("character-panel") {
        el.set_inner_html("");
    }
    if let Some(el) = doc.get_element_by_id("trpg-overview-summary") {
        el.set_inner_html("<div class=\"trpg-summary-empty\">개요를 불러오는 중입니다.</div>");
    }
    if let Some(el) = doc.get_element_by_id("trpg-overview-alarms") {
        el.set_inner_html("<div class=\"trpg-summary-empty\">알림을 불러오는 중입니다.</div>");
    }
    if let Some(el) = doc.get_element_by_id("trpg-overview-actions") {
        el.set_inner_html("<div class=\"trpg-summary-empty\">다음 액션을 계산 중입니다.</div>");
    }
    if let Some(el) = doc.get_element_by_id("trpg-control-summary") {
        el.set_inner_html("<div class=\"trpg-summary-empty\">제어 상태를 불러오는 중입니다.</div>");
    }
    if let Some(el) = doc.get_element_by_id("trpg-control-warnings") {
        el.set_inner_html("<div class=\"trpg-summary-empty\">운영 경고를 불러오는 중입니다.</div>");
    }
    if let Some(el) = doc.get_element_by_id("trpg-control-actions") {
        el.set_inner_html("<div class=\"trpg-summary-empty\">허용된 액션을 계산 중입니다.</div>");
    }
    if let Some(el) = doc.get_element_by_id("trpg-timeline-summary") {
        el.set_inner_html(
            "<div class=\"trpg-summary-empty\">타임라인 요약을 불러오는 중입니다.</div>",
        );
    }
    if let Some(el) = doc.get_element_by_id("trpg-timeline-events") {
        el.set_inner_html(
            "<div class=\"trpg-summary-empty\">최근 이벤트를 불러오는 중입니다.</div>",
        );
    }
    if let Some(el) = doc.get_element_by_id("turn-num") {
        el.set_text_content(Some("1"));
    }
    if let Some(el) = doc.get_element_by_id("turn-runtime") {
        el.set_inner_html("");
    }
    if let Some(el) = doc.get_element_by_id("turn-flow-banner") {
        let _ = el.set_attribute("class", "turn-flow-banner is-idle");
        let _ = el.set_attribute("title", "세션 상태를 불러오는 중입니다.");
    }
    if let Some(el) = doc.get_element_by_id("turn-flow-state") {
        el.set_text_content(Some("대기"));
    }
    if let Some(el) = doc.get_element_by_id("turn-flow-text") {
        el.set_text_content(Some("세션 상태를 불러오는 중입니다."));
    }
    if let Some(el) = doc.get_element_by_id("turn-flow-actions") {
        el.set_inner_html("");
        let _ = el.remove_attribute("data-snapshot");
    }
    if let Some(el) = doc.get_element_by_id("agent-round-flow") {
        el.set_inner_html(
            "<div class=\"agent-flow-empty\">에이전트 라운드 흐름을 불러오는 중입니다.</div>",
        );
    }
    if let Some(el) = doc.get_element_by_id("turn-controls") {
        let _ = el.set_attribute("style", "display:none");
    }
    if let Some(el) = doc.get_element_by_id("turn-control-status") {
        el.set_text_content(Some(""));
        let _ = el.set_attribute("class", "");
    }
    if let Some(el) = doc.get_element_by_id("turn-control-gate") {
        el.set_text_content(Some("실행 조건 점검 중..."));
        let _ = el.set_attribute("class", "turn-control-gate status-info");
    }
    if let Some(el) = doc.get_element_by_id("round-readiness-checklist") {
        el.set_text_content(Some(""));
        let _ = el.remove_attribute("data-snapshot");
    }
    if let Some(el) = doc.get_element_by_id("action-panel") {
        let _ = el.set_attribute("style", "display:none");
    }
    if let Some(el) = doc.get_element_by_id("join-status") {
        el.set_text_content(Some(""));
    }
    if let Some(el) = doc.get_element_by_id("new-game-assignment") {
        el.set_inner_html("세션 정보를 준비 중입니다.");
    }
    if let Some(el) = doc.get_element_by_id("action-status") {
        el.set_text_content(Some(""));
    }
    if let Some(input) = doc
        .get_element_by_id("claimed-actor-id")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_value("");
    }
    if let Some(input) = doc
        .get_element_by_id("claimed-keeper")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_value("");
    }
    if let Some(input) = doc
        .get_element_by_id("round-run-phase")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_value("round");
    }
    if let Some(input) = doc
        .get_element_by_id("round-run-timeout")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_value("45");
    }
    if let Some(input) = doc
        .get_element_by_id("round-run-lang")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_value("ko");
    }
    if let Some(summary) = doc.get_element_by_id("round-run-summary") {
        summary.set_text_content(Some(""));
        let _ = summary.set_attribute("style", "display:none");
    }
    if let Some(badges) = doc.get_element_by_id("round-run-badges") {
        badges.set_text_content(Some(""));
        let _ = badges.set_attribute("style", "display:none");
    }
    if let Some(dashboard) = doc.get_element_by_id("dashboard") {
        let _ = dashboard.set_attribute("data-history-focus", "latest");
        let _ = dashboard.set_attribute("data-dedup-stream", "0");
        let _ = dashboard.set_attribute("data-dedup-narrative", "0");
        let _ = dashboard.set_attribute("data-dedup-history", "0");
        let _ = dashboard.set_attribute("data-dedup-samples-stream", "");
        let _ = dashboard.set_attribute("data-dedup-samples-narrative", "");
        let _ = dashboard.set_attribute("data-dedup-samples-history", "");
    }
    if let Some(btn) = doc.get_element_by_id("dedup-status") {
        let _ = btn.set_attribute("aria-expanded", "false");
    }
    if let Some(popover) = doc.get_element_by_id("dedup-popover") {
        if let Some(el) = popover.dyn_ref::<web_sys::HtmlElement>() {
            let _ = el.style().set_property("display", "none");
        }
        popover.set_inner_html("");
    }
}

#[cfg(target_arch = "wasm32")]
pub(super) fn unique_non_empty(mut values: Vec<String>) -> Vec<String> {
    values.retain(|v| !v.trim().is_empty());
    let mut out = Vec::with_capacity(values.len());
    for value in values {
        if out.iter().any(|x: &String| x == &value) {
            continue;
        }
        out.push(value);
    }
    out
}

#[cfg(any(target_arch = "wasm32", test))]
pub(super) fn assign_keepers_to_actor_ids(
    actor_ids: &[String],
    dm_keeper: &str,
    player_keepers: &[String],
) -> Result<Vec<(String, String)>, String> {
    if actor_ids.is_empty() {
        return Err("세션 party actor_id를 읽지 못했습니다.".to_string());
    }
    if player_keepers.len() < actor_ids.len() {
        return Err(format!(
            "player keeper가 부족합니다. actor {}명에 keeper {}명만 선택되었습니다.",
            actor_ids.len(),
            player_keepers.len()
        ));
    }

    let mut assigned = Vec::with_capacity(actor_ids.len());
    let mut used_keepers = vec![dm_keeper.trim().to_string()];

    for (idx, actor_id) in actor_ids.iter().enumerate() {
        let keeper = player_keepers
            .get(idx)
            .map(|name| name.trim().to_string())
            .filter(|name| !name.is_empty())
            .ok_or_else(|| format!("actor {}에 할당할 keeper가 비어 있습니다.", actor_id))?;

        if keeper == dm_keeper {
            return Err(format!(
                "DM keeper와 player keeper는 중복될 수 없습니다: {}",
                keeper
            ));
        }
        if used_keepers.iter().any(|name| name == &keeper) {
            return Err(format!(
                "player keeper는 모두 유일해야 합니다. 중복: {}",
                keeper
            ));
        }
        used_keepers.push(keeper.clone());
        assigned.push((actor_id.clone(), keeper));
    }

    Ok(assigned)
}

#[cfg(target_arch = "wasm32")]
fn format_round_plan_for_display(dm_keeper: &str, players: &[(String, String)]) -> String {
    let mut lines = vec![format!("DM: {}", dm_keeper)];
    if players.is_empty() {
        lines.push("Players: -".to_string());
        return lines.join(" · ");
    }
    let player_text = players
        .iter()
        .map(|(actor_id, keeper)| format!("{}→{}", actor_id, keeper))
        .collect::<Vec<_>>()
        .join(", ");
    lines.push(format!("Players: {}", player_text));
    lines.join(" · ")
}

#[cfg(target_arch = "wasm32")]
pub(super) fn set_round_run_fields(
    doc: &web_sys::Document,
    dm_keeper: &str,
    actor_ids: &[String],
    player_map: &std::collections::HashMap<String, String>,
) {
    if let Some(el) = doc
        .get_element_by_id("round-run-dm")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        el.set_value(dm_keeper);
    }
    if let Some(el) = doc
        .get_element_by_id("round-run-phase")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        el.set_value("round");
    }
    if let Some(el) = doc
        .get_element_by_id("round-run-timeout")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        el.set_value("45");
    }
    if let Some(el) = doc
        .get_element_by_id("round-run-lang")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        el.set_value("ko");
    }

    let player_pairs = actor_ids
        .iter()
        .filter_map(|actor_id| player_map.get(actor_id).map(|keeper| (actor_id, keeper)))
        .map(|(actor_id, keeper)| format!("{}={}", actor_id, keeper))
        .collect::<Vec<_>>();
    if let Some(el) = doc
        .get_element_by_id("round-run-players")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        el.set_value(&player_pairs.join(","));
    }

    let summary_pairs = actor_ids
        .iter()
        .filter_map(|actor_id| {
            player_map
                .get(actor_id)
                .map(|keeper| (actor_id.clone(), keeper.clone()))
        })
        .collect::<Vec<(String, String)>>();
    if let Some(summary) = doc.get_element_by_id("round-run-summary") {
        summary.set_text_content(Some(&format_round_plan_for_display(
            dm_keeper,
            &summary_pairs,
        )));
        let _ = summary.set_attribute("style", "display:block");
    }
}

mod transport_classify;

#[cfg(target_arch = "wasm32")]
mod mcp_rpc;
#[cfg(target_arch = "wasm32")]
use mcp_rpc::mcp_tool_call;

#[cfg(target_arch = "wasm32")]
mod workspace_hub;
#[cfg(target_arch = "wasm32")]
use workspace_hub::{
    bind_workspace_controls, candidate_workspace_ids, load_known_workspaces,
    refresh_workspaces_from_server, remember_recent_workspace, sync_workspace_controls,
};

#[path = "../../../archive/trpg/viewer/trpg_controls.rs"]
#[cfg(target_arch = "wasm32")]
mod trpg_controls;
#[cfg(target_arch = "wasm32")]
use trpg_controls::{
    actor_admin_set_status, actor_admin_workspace_id, bind_new_game_controls,
    refresh_actor_admin_list, refresh_trpg_ops_snapshots,
};

/// Refresh TRPG widget status counters (narrative, party, history, dedup).
/// On non-wasm targets this is a no-op; on wasm32 it delegates to `trpg_controls`.
fn refresh_trpg_widget_status() {
    #[cfg(target_arch = "wasm32")]
    trpg_controls::refresh_trpg_widget_status();
}

#[cfg(target_arch = "wasm32")]
fn set_element_text(doc: &web_sys::Document, id: &str, text: &str) {
    if let Some(el) = doc.get_element_by_id(id) {
        el.set_text_content(Some(text));
    }
}

#[cfg(target_arch = "wasm32")]
fn get_element_text(doc: &web_sys::Document, id: &str) -> String {
    doc.get_element_by_id(id)
        .and_then(|el| el.text_content())
        .unwrap_or_default()
}

#[cfg(target_arch = "wasm32")]
fn set_or_prepend_line(
    doc: &web_sys::Document,
    id: &str,
    line: &str,
    placeholder_hints: &[&str],
    max_lines: usize,
) {
    let current = get_element_text(doc, id);
    let trimmed = current.trim();
    let should_replace = trimmed.is_empty()
        || placeholder_hints
            .iter()
            .any(|hint| !hint.trim().is_empty() && trimmed.contains(hint));

    if should_replace {
        set_element_text(doc, id, line);
        return;
    }

    let current_lines = current
        .lines()
        .map(str::trim)
        .filter(|row| !row.is_empty())
        .collect::<Vec<_>>();
    if current_lines.first().is_some_and(|first| *first == line) {
        return;
    }

    let mut merged = Vec::with_capacity(current_lines.len() + 1);
    merged.push(line.to_string());
    merged.extend(current_lines.into_iter().map(ToString::to_string));
    merged.truncate(max_lines.max(1));
    set_element_text(doc, id, &merged.join("\n"));
}

#[cfg(target_arch = "wasm32")]
fn summarize_keeper_names(payload: &Value, limit: usize) -> String {
    let keepers = payload
        .get("keepers")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    keepers
        .iter()
        .filter_map(|row| row.get("name").and_then(Value::as_str))
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .take(limit)
        .collect::<Vec<_>>()
        .join(", ")
}

#[cfg(target_arch = "wasm32")]
async fn seed_monitor_snapshot(doc: web_sys::Document) -> Result<(), String> {
    let keepers_payload = mcp_tool_call("masc_keeper_list", json!({ "limit": 200 })).await?;
    let keeper_count = keepers_payload
        .get("count")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let keeper_preview = summarize_keeper_names(&keepers_payload, 6);
    let keepers_text = if keeper_preview.is_empty() {
        format!("등록 keeper: {}명", keeper_count)
    } else {
        format!(
            "등록 keeper: {}명\n대표 keeper: {}",
            keeper_count, keeper_preview
        )
    };
    set_element_text(&doc, "monitor-agent-list", &keepers_text);

    let current_workspace = crate::config::current_workspace_id();
    let tracked_workspaces = candidate_workspace_ids();
    let known_workspace_count = load_known_workspaces().len();
    let workspace_count = tracked_workspaces.len();
    set_element_text(
        &doc,
        "monitor-task-list",
        &format!(
            "현재 workspace: {}\n추적 workspace: {}개 (known {}개)",
            current_workspace, workspace_count, known_workspace_count
        ),
    );
    set_or_prepend_line(
        &doc,
        "monitor-events",
        &format!(
            "[snapshot] current workspace {} / tracked workspaces {}개 / keeper {}명 초기 상태 로드",
            current_workspace,
            workspace_count, keeper_count
        ),
        &["Waiting for events...", "No events yet"],
        50,
    );
    Ok(())
}

#[cfg(target_arch = "wasm32")]
async fn seed_experiment_snapshot(doc: web_sys::Document) -> Result<(), String> {
    let payload = match mcp_tool_call("experiment_list", json!({ "limit": 20 })).await {
        Ok(payload) => payload,
        Err(err) if err.contains("not available on this MCP endpoint") => {
            set_or_prepend_line(
                &doc,
                "experiment-dashboard",
                "[snapshot] experiment surface unavailable on current MCP endpoint",
                &["No experiments running."],
                80,
            );
            return Ok(());
        }
        Err(err) => return Err(err),
    };
    let total = payload.get("total").and_then(Value::as_i64).unwrap_or(0);
    let experiments = payload
        .get("experiments")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let running_count = experiments
        .iter()
        .filter(|row| row.get("status").and_then(Value::as_str) == Some("running"))
        .count();
    let latest = experiments.first().and_then(|row| {
        let id = row.get("id").and_then(Value::as_str)?;
        let hypothesis = row.get("hypothesis").and_then(Value::as_str).unwrap_or("-");
        Some(format!("{}: {}", id, hypothesis))
    });
    let line = match latest {
        Some(top) => format!(
            "[snapshot] 실험 {}개 (running {}) · 최신 {}",
            total, running_count, top
        ),
        None => format!("[snapshot] 실험 {}개 (running {})", total, running_count),
    };
    set_or_prepend_line(
        &doc,
        "experiment-dashboard",
        &line,
        &["No experiments running."],
        80,
    );
    Ok(())
}

#[cfg(target_arch = "wasm32")]
fn seed_masc_panel_snapshot(mode: ViewerMode, doc: web_sys::Document) {
    wasm_bindgen_futures::spawn_local(async move {
        let result = match mode {
            ViewerMode::Monitor => seed_monitor_snapshot(doc.clone()).await,
            ViewerMode::Experiment => seed_experiment_snapshot(doc.clone()).await,
            _ => Ok(()),
        };
        if let Err(e) = result {
            log::warn!("MASC snapshot seed failed for {:?}: {}", mode, e);
        }
    });
}

#[cfg(target_arch = "wasm32")]
fn count_mode_events(mode: ViewerMode, event_log: &crate::sse::masc_bridge::MascEventLog) -> usize {
    match mode {
        ViewerMode::Monitor => event_log.entries.len(),
        ViewerMode::Experiment => event_log
            .entries
            .iter()
            .filter(|entry| entry.event_type.starts_with("experiment_"))
            .count(),
        ViewerMode::Social => event_log
            .entries
            .iter()
            .filter(|entry| entry.event_type == "broadcast")
            .count(),
        _ => 0,
    }
}

fn sync_masc_panel_connection_status(
    mode: Res<State<ViewerMode>>,
    connection: Res<ConnectionStatus>,
    event_log: Option<Res<crate::sse::masc_bridge::MascEventLog>>,
) {
    #[cfg(target_arch = "wasm32")]
    {
        let current_mode = *mode.get();
        let Some(status_badge_id) = current_mode.status_badge_id() else {
            return;
        };
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let Some(el) = doc.get_element_by_id(status_badge_id) else {
            return;
        };

        let mode_event_count = event_log
            .as_ref()
            .map(|log| count_mode_events(current_mode, log))
            .unwrap_or(0);

        let (status_class, text) = match &*connection {
            ConnectionStatus::Connected => match current_mode {
                ViewerMode::Social if mode_event_count == 0 => {
                    ("status-connected", "연결됨 · 게시글 폴링 중".to_string())
                }
                ViewerMode::Social => (
                    "status-connected",
                    format!("연결됨 · 게시글 폴링 + 알림 {}건", mode_event_count),
                ),
                _ if mode_event_count == 0 => {
                    ("status-connected", "연결됨 · 이벤트 대기 중".to_string())
                }
                _ => (
                    "status-connected",
                    format!("연결됨 · 이벤트 {}건 수신", mode_event_count),
                ),
            },
            ConnectionStatus::Connecting => ("status-connecting", "연결 중...".to_string()),
            ConnectionStatus::Reconnecting(attempt, max) => (
                "status-connecting",
                format!("재연결 중 ({}/{})", attempt, max),
            ),
            ConnectionStatus::Disconnected => ("status-disconnected", "연결 대기 중".to_string()),
            ConnectionStatus::Failed => ("status-disconnected", "연결 실패".to_string()),
        };

        el.set_class_name(&format!("mode-status {}", status_class));
        el.set_text_content(Some(&text));
    }

    let _ = (&mode, &connection, &event_log);
}

// ─── Generic MASC Panel Enter/Exit ───────────

/// Generic enter handler for MASC mode panels (Monitor, Social, Experiment).
/// Shows the mode's panel, hides home and dashboard, binds back navigation.
fn enter_masc_panel(mode: Res<State<ViewerMode>>, buffer: Res<ModeTransitionBuffer>) {
    #[cfg(target_arch = "wasm32")]
    {
        let current_mode = *mode.get();
        let Some(panel_id) = current_mode.panel_id() else {
            return;
        };
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        set_panel_active(&doc, panel_id, true);
        set_element_display(&doc, "home-screen", "none");
        set_element_display(&doc, "dashboard", "none");

        bind_back_buttons(&doc, &buffer.pending);
        seed_masc_panel_snapshot(current_mode, doc.clone());
    }
    let _ = (&mode, &buffer);
}

/// Generic exit handler for MASC mode panels.
/// Hides all mode panels rather than determining which one — State<> may already
/// reflect the new state during OnExit, and the cost of 4 getElementById calls is negligible.
fn exit_masc_panel() {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        for panel_id in &["monitor-panel", "social-panel", "experiment-panel"] {
            set_panel_active(&doc, panel_id, false);
        }
    }
}

// ─── DOM Helpers ─────────────────────────────

/// Helper to set display style on a DOM element by ID.
/// Used for home-screen (flex) and dashboard (grid/none) which don't use CSS transitions.
#[cfg(target_arch = "wasm32")]
pub(super) fn set_element_display(doc: &web_sys::Document, id: &str, display: &str) {
    if let Some(el) = doc.get_element_by_id(id) {
        if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
            let _ = html_el.style().set_property("display", display);
        }
    }
}

/// Toggles the `active` CSS class on a mode panel for animated show/hide.
/// CSS `.mode-panel` uses opacity+visibility transitions; `.mode-panel.active` makes it visible.
#[cfg(target_arch = "wasm32")]
fn set_panel_active(doc: &web_sys::Document, id: &str, active: bool) {
    if let Some(el) = doc.get_element_by_id(id) {
        let class_list = el.class_list();
        if active {
            let _ = class_list.add_1("active");
        } else {
            let _ = class_list.remove_1("active");
        }

        if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
            let _ = if active {
                html_el.style().set_property("display", "block")
            } else {
                html_el.style().set_property("display", "none")
            };
        }
    }
}

/// Binds all `.back-btn[data-back]` buttons to transition back to Home.
#[cfg(target_arch = "wasm32")]
fn bind_back_buttons(doc: &web_sys::Document, pending: &Arc<Mutex<Option<ViewerMode>>>) {
    let Ok(buttons) = doc.query_selector_all("[data-back]") else {
        return;
    };

    for i in 0..buttons.length() {
        let Some(btn) = buttons.item(i) else { continue };

        // Guard: skip buttons already bound to prevent closure accumulation
        if let Some(el) = btn.dyn_ref::<web_sys::Element>() {
            if el.get_attribute("data-bound").as_deref() == Some("1") {
                continue;
            }
            let _ = el.set_attribute("data-bound", "1");
        }

        let buf = pending.clone();
        let cb = Closure::wrap(Box::new(move |_: web_sys::Event| {
            if let Ok(mut guard) = buf.lock() {
                *guard = Some(ViewerMode::Home);
            }
        }) as Box<dyn FnMut(web_sys::Event)>);

        if let Some(target) = btn.dyn_ref::<web_sys::EventTarget>() {
            let _ = target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref());
        }
        cb.forget();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panel_id_returns_correct_ids_for_masc_modes() {
        assert_eq!(ViewerMode::Monitor.panel_id(), Some("monitor-panel"));
        assert_eq!(ViewerMode::Social.panel_id(), Some("social-panel"));
        assert_eq!(ViewerMode::Experiment.panel_id(), Some("experiment-panel"));
    }

    #[test]
    fn panel_id_returns_none_for_non_panel_modes() {
        assert_eq!(ViewerMode::Home.panel_id(), None);
        assert_eq!(ViewerMode::Trpg.panel_id(), None);
    }

    #[test]
    fn assign_keepers_success_with_unique_names() {
        let actors = vec!["p01".to_string(), "p02".to_string()];
        let keepers = vec!["grimja".to_string(), "luna".to_string()];
        let assigned =
            assign_keepers_to_actor_ids(&actors, "dm-keeper", &keepers).expect("assignment ok");
        assert_eq!(
            assigned,
            vec![
                ("p01".to_string(), "grimja".to_string()),
                ("p02".to_string(), "luna".to_string())
            ]
        );
    }

    #[test]
    fn assign_keepers_fails_when_players_are_missing() {
        let actors = vec!["p01".to_string(), "p02".to_string(), "p03".to_string()];
        let keepers = vec!["grimja".to_string(), "luna".to_string()];
        let err = assign_keepers_to_actor_ids(&actors, "dm-keeper", &keepers)
            .expect_err("must fail on keeper shortage");
        assert!(err.contains("부족"), "unexpected error: {err}");
    }

    #[test]
    fn assign_keepers_fails_on_duplicate_or_dm_collision() {
        let actors = vec!["p01".to_string(), "p02".to_string()];
        let dup = vec!["grimja".to_string(), "grimja".to_string()];
        let err_dup =
            assign_keepers_to_actor_ids(&actors, "dm-keeper", &dup).expect_err("duplicate keeper");
        assert!(err_dup.contains("중복"), "unexpected error: {err_dup}");

        let dm_collision = vec!["dm-keeper".to_string(), "luna".to_string()];
        let err_dm = assign_keepers_to_actor_ids(&actors, "dm-keeper", &dm_collision)
            .expect_err("dm collision must fail");
        assert!(err_dm.contains("DM keeper"), "unexpected error: {err_dm}");
    }
}
