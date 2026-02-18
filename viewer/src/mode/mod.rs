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
use wasm_bindgen_futures::JsFuture;
#[cfg(target_arch = "wasm32")]
use crate::game::lifecycle::TrpgLifecycleState;
#[cfg(target_arch = "wasm32")]
use crate::dom::escape::html_escape;

/// Top-level viewer mode. Determines which plugins/systems are active
/// and which SSE endpoint the viewer connects to.
#[derive(States, Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ViewerMode {
    /// Mode selection screen. No SSE connection, no game state.
    #[default]
    Lobby,

    /// D&D 5e game session viewer (그림란드 연대기).
    /// Data source:
    /// - default: MASC `/api/v1/trpg/stream` JSON polling
    /// - optional: legacy TRPG Engine `/rooms/:id/stream` SSE
    Trpg,

    /// Experiment visualization — Sankey diagrams, network graphs, A/B metrics.
    /// SSE: MASC `/sse?room=experiment`
    Experiment,

    /// System monitor — keeper metrics, agent health, heartbeat dashboard.
    /// SSE: MASC `/sse?room=monitor`
    Monitor,

    /// MAGI council deliberation viewer — consensus voting, debate flow.
    /// SSE: MASC `/sse?room=council`
    Council,

    /// Lodge social feed — agent board posts, comments, reactions.
    /// SSE: MASC `/sse?room=social`
    Social,
}

#[allow(dead_code)]
impl ViewerMode {
    /// Human-readable display name for UI rendering.
    /// Used by `poll_mode_transition` (wasm32 only).
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Lobby => "MASC Viewer",
            Self::Trpg => "그림란드 연대기",
            Self::Experiment => "Experiment Lab",
            Self::Monitor => "System Monitor",
            Self::Council => "MAGI Council",
            Self::Social => "The Lodge",
        }
    }

    /// DOM panel element ID for MASC mode panels.
    /// Returns `None` for Lobby and Trpg (they use different layout).
    pub fn panel_id(&self) -> Option<&'static str> {
        match self {
            Self::Monitor => Some("monitor-panel"),
            Self::Council => Some("council-panel"),
            Self::Social => Some("social-panel"),
            Self::Experiment => Some("experiment-panel"),
            _ => None,
        }
    }

    /// CSS class name applied to the HTML body for mode-specific DOM styling.
    /// Used by `poll_mode_transition` (wasm32 only).
    pub fn css_class(&self) -> &'static str {
        match self {
            Self::Lobby => "mode-lobby",
            Self::Trpg => "mode-trpg",
            Self::Experiment => "mode-experiment",
            Self::Monitor => "mode-monitor",
            Self::Council => "mode-council",
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
            "council" => Some(Self::Council),
            "social" => Some(Self::Social),
            _ => None,
        }
    }
}

// ─── Shared Buffer Resource ──────────────────

/// Holds pending mode transitions from JS click events.
/// The JS closure writes here; a Bevy Update system drains it.
#[derive(Resource)]
pub struct ModeTransitionBuffer {
    #[cfg(target_arch = "wasm32")]
    pending: Arc<Mutex<Option<ViewerMode>>>,
    #[cfg(not(target_arch = "wasm32"))]
    _phantom: (),
}

impl Default for ModeTransitionBuffer {
    fn default() -> Self {
        Self {
            #[cfg(target_arch = "wasm32")]
            pending: Arc::new(Mutex::new(None)),
            #[cfg(not(target_arch = "wasm32"))]
            _phantom: (),
        }
    }
}

// ─── Plugin ──────────────────────────────────

/// Plugin that registers the ViewerMode state and mode transition systems.
pub struct ModePlugin;

impl Plugin for ModePlugin {
    fn build(&self, app: &mut App) {
        app.init_state::<ViewerMode>()
            .init_resource::<ModeTransitionBuffer>()
            .add_systems(OnEnter(ViewerMode::Lobby), on_enter_lobby)
            .add_systems(OnExit(ViewerMode::Lobby), on_exit_lobby)
            .add_systems(OnEnter(ViewerMode::Trpg), enter_trpg)
            .add_systems(OnExit(ViewerMode::Trpg), exit_trpg)
            .add_systems(OnEnter(ViewerMode::Monitor), enter_masc_panel)
            .add_systems(OnExit(ViewerMode::Monitor), exit_masc_panel)
            .add_systems(OnEnter(ViewerMode::Council), enter_masc_panel)
            .add_systems(OnExit(ViewerMode::Council), exit_masc_panel)
            .add_systems(OnEnter(ViewerMode::Social), enter_masc_panel)
            .add_systems(OnExit(ViewerMode::Social), exit_masc_panel)
            .add_systems(OnEnter(ViewerMode::Experiment), enter_masc_panel)
            .add_systems(OnExit(ViewerMode::Experiment), exit_masc_panel)
            .add_systems(
                Update,
                refresh_trpg_widget_status.run_if(in_state(ViewerMode::Trpg)),
            )
            .add_systems(Update, poll_mode_transition);
    }
}

// ─── Lobby Enter/Exit ────────────────────────

/// Startup logic when entering Lobby mode: show lobby UI, bind click listeners.
fn on_enter_lobby(buffer: Res<ModeTransitionBuffer>) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        clear_trpg_dom(&doc);
        let lobby_room = crate::config::current_room_id();
        crate::config::set_current_room_id(&lobby_room);
        // Show lobby UI, hide dashboard
        if let Some(body) = doc.body() {
            body.set_class_name("mode-lobby");
        }
        set_element_display(&doc, "lobby-screen", "flex");
        set_element_display(&doc, "dashboard", "none");

        // Bind mode card clicks
        bind_mode_cards(&doc, &buffer.pending);

        // Bind back-to-lobby button
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
    }

    // Suppress unused warning on native
    let _ = &buffer;
}

/// Cleanup when leaving Lobby mode (entering a visualization mode).
fn on_exit_lobby() {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        set_element_display(&doc, "lobby-screen", "none");
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
        set_element_display(&doc, "lobby-screen", "none");
        set_element_display(&doc, "new-game-panel", "none");
        clear_trpg_dom(&doc);
        bind_debug_controls(&doc);
        bind_new_game_controls(&doc);
        let room = crate::config::current_room_id();
        set_current_room_id(&doc, &room);
        bind_room_controls(&doc);

        if let Some(pill) = doc.get_element_by_id("room-status") {
            pill.set_text_content(Some(&format!("현재 방: {} · 목록 불러오는 중...", room)));
        }
        let doc_for_rooms = doc.clone();
        wasm_bindgen_futures::spawn_local(async move {
            match refresh_rooms_from_server(&doc_for_rooms).await {
                Ok(rooms) => {
                    let room_now = crate::config::current_room_id();
                    if let Some(pill) = doc_for_rooms.get_element_by_id("room-status") {
                        pill.set_text_content(Some(&format!(
                            "현재 방: {} · {}개 방",
                            room_now,
                            rooms.len()
                        )));
                    }
                }
                Err(e) => {
                    log::warn!("room 목록 로딩 실패: {}", e);
                    let room_now = crate::config::current_room_id();
                    if let Some(pill) = doc_for_rooms.get_element_by_id("room-status") {
                        pill.set_text_content(Some(&format!("현재 방: {} · 목록 실패", room_now)));
                    }
                }
            }
        });
    }
}

fn exit_trpg() {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        set_element_display(&doc, "new-game-panel", "none");
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
    // Guard: only bind once to prevent closure accumulation on repeated lobby entries
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

/// Binds the `#back-to-lobby` button to transition back to Lobby.
#[cfg(target_arch = "wasm32")]
fn bind_back_button(doc: &web_sys::Document, pending: &Arc<Mutex<Option<ViewerMode>>>) {
    let Some(btn) = doc.get_element_by_id("back-to-lobby") else {
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
            *guard = Some(ViewerMode::Lobby);
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
pub(super) fn generate_room_id() -> String {
    let millis = js_sys::Date::now() as i64;
    let rand = (js_sys::Math::random() * 1000.0).floor() as i64;
    format!("adventure-{}-{:03}", millis, rand)
}

#[cfg(target_arch = "wasm32")]
pub(super) fn set_new_game_status(doc: &web_sys::Document, message: &str) {
    if let Some(el) = doc.get_element_by_id("new-game-status") {
        el.set_inner_html(&html_escape(message));
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
pub(super) fn set_new_game_preflight_rows(doc: &web_sys::Document, rows: &[(bool, String, String)]) {
    if let Some(el) = doc.get_element_by_id("new-game-preflight") {
        let html = rows
            .iter()
            .map(|(ok, label, detail)| {
                let state_text = if *ok { "OK" } else { "FAIL" };
                let state_class = if *ok {
                    "preflight-state preflight-ok"
                } else {
                    "preflight-state preflight-fail"
                };
                format!(
                    "<div class=\"preflight-row\"><span class=\"{state_class}\">{state_text}</span><span>{label}: {detail}</span></div>",
                    state_class = state_class,
                    state_text = state_text,
                    label = html_escape(label),
                    detail = html_escape(detail),
                )
            })
            .collect::<Vec<_>>()
            .join("");
        el.set_inner_html(&html);
    }
}

#[cfg(target_arch = "wasm32")]
pub(super) fn set_current_room_id(doc: &web_sys::Document, room_id: &str) {
    crate::config::set_current_room_id(room_id);
    let room = crate::config::current_room_id();
    if let Some(dashboard) = doc.get_element_by_id("dashboard") {
        let _ = dashboard.set_attribute("data-room-id", &room);
    }
    remember_recent_room(&room);
    sync_room_controls(doc, &room);
}

#[cfg(target_arch = "wasm32")]
pub(super) fn clear_trpg_dom(doc: &web_sys::Document) {
    if let Some(dashboard) = doc.get_element_by_id("dashboard") {
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
    if let Some(el) = doc.get_element_by_id("turn-num") {
        el.set_text_content(Some("1"));
    }
    if let Some(el) = doc.get_element_by_id("turn-runtime") {
        el.set_inner_html("");
    }
    if let Some(el) = doc.get_element_by_id("turn-controls") {
        let _ = el.set_attribute("style", "display:none");
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
        .get_element_by_id("round-run-dm")
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
        input.set_value("90");
    }
    if let Some(input) = doc
        .get_element_by_id("round-run-lang")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_value("ko");
    }
    if let Some(input) = doc
        .get_element_by_id("round-run-players")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_value("");
    }
    if let Some(summary) = doc.get_element_by_id("round-run-summary") {
        summary.set_text_content(Some(""));
        let _ = summary.set_attribute("style", "display:none");
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
        el.set_value("90");
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


#[cfg(target_arch = "wasm32")]
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

#[cfg(target_arch = "wasm32")]
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

#[cfg(target_arch = "wasm32")]
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

#[cfg(target_arch = "wasm32")]
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

#[cfg(target_arch = "wasm32")]
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

#[cfg(target_arch = "wasm32")]
fn save_known_rooms(rooms: &[String]) {
    let value = rooms.join("\n");
    if let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten()) {
        let _ = storage.set_item(KNOWN_ROOMS_STORAGE_KEY, &value);
    }
}

#[cfg(target_arch = "wasm32")]
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

#[cfg(target_arch = "wasm32")]
fn save_room_hub_visible(visible: bool) {
    if let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten()) {
        let _ = storage.set_item(
            ROOM_HUB_VISIBLE_STORAGE_KEY,
            if visible { "1" } else { "0" },
        );
    }
}

#[cfg(target_arch = "wasm32")]
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

#[cfg(target_arch = "wasm32")]
fn save_room_hub_running_only(enabled: bool) {
    if let Some(storage) = web_sys::window().and_then(|w| w.local_storage().ok().flatten()) {
        let _ = storage.set_item(
            ROOM_HUB_RUNNING_ONLY_STORAGE_KEY,
            if enabled { "1" } else { "0" },
        );
    }
}

#[cfg(target_arch = "wasm32")]
fn set_room_hub_visible(doc: &web_sys::Document, visible: bool) {
    set_element_display(doc, "room-hub", if visible { "grid" } else { "none" });
    if let Some(toggle) = doc.get_element_by_id("room-hub-toggle") {
        let _ = toggle.set_attribute("aria-pressed", if visible { "true" } else { "false" });
        toggle.set_text_content(Some(if visible { "방 목록 닫기" } else { "방 목록" }));
    }
}

#[cfg(target_arch = "wasm32")]
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

#[cfg(target_arch = "wasm32")]
fn sync_room_controls(doc: &web_sys::Document, selected_room: &str) {
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

#[cfg(target_arch = "wasm32")]
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

#[cfg(target_arch = "wasm32")]
async fn refresh_rooms_from_server(doc: &web_sys::Document) -> Result<Vec<RoomSnapshot>, String> {
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

#[cfg(target_arch = "wasm32")]
fn bind_room_controls(doc: &web_sys::Document) {
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

#[cfg(target_arch = "wasm32")]
mod mcp_rpc;
#[cfg(target_arch = "wasm32")]
use mcp_rpc::{mcp_tool_call, parse_embedded_tool_payload};

#[cfg(target_arch = "wasm32")]
mod room_hub;
#[cfg(target_arch = "wasm32")]
use room_hub::{
    load_recent_rooms, remember_recent_room, room_lane_label, RoomSnapshot,
    KNOWN_ROOMS_STORAGE_KEY, ROOM_HUB_RUNNING_ONLY_STORAGE_KEY, ROOM_HUB_VISIBLE_STORAGE_KEY,
};

#[cfg(target_arch = "wasm32")]
mod trpg_controls;
#[cfg(target_arch = "wasm32")]
use trpg_controls::{
    actor_admin_room_id, actor_admin_set_status, bind_new_game_controls,
    refresh_actor_admin_list,
};

/// Refresh TRPG widget status counters (narrative, party, history, dedup).
/// On non-wasm targets this is a no-op; on wasm32 it delegates to `trpg_controls`.
fn refresh_trpg_widget_status() {
    #[cfg(target_arch = "wasm32")]
    trpg_controls::refresh_trpg_widget_status();
}


// ─── Generic MASC Panel Enter/Exit ───────────

/// Generic enter handler for MASC mode panels (Monitor, Council, Social, Experiment).
/// Shows the mode's panel, hides lobby and dashboard, binds back navigation.
fn enter_masc_panel(mode: Res<State<ViewerMode>>, buffer: Res<ModeTransitionBuffer>) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(panel_id) = mode.get().panel_id() else {
            return;
        };
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        set_panel_active(&doc, panel_id, true);
        set_element_display(&doc, "lobby-screen", "none");
        set_element_display(&doc, "dashboard", "none");

        bind_back_buttons(&doc, &buffer.pending);
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
        for panel_id in &[
            "monitor-panel",
            "council-panel",
            "social-panel",
            "experiment-panel",
        ] {
            set_panel_active(&doc, panel_id, false);
        }
    }
}

// ─── DOM Helpers ─────────────────────────────

/// Helper to set display style on a DOM element by ID.
/// Used for lobby-screen (flex) and dashboard (grid/none) which don't use CSS transitions.
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

/// Binds all `.back-btn[data-back]` buttons to transition back to Lobby.
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
                *guard = Some(ViewerMode::Lobby);
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
        assert_eq!(ViewerMode::Council.panel_id(), Some("council-panel"));
        assert_eq!(ViewerMode::Social.panel_id(), Some("social-panel"));
        assert_eq!(ViewerMode::Experiment.panel_id(), Some("experiment-panel"));
    }

    #[test]
    fn panel_id_returns_none_for_non_panel_modes() {
        assert_eq!(ViewerMode::Lobby.panel_id(), None);
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
