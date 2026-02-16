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
use std::sync::{Arc, Mutex};

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;

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
            .add_systems(OnEnter(ViewerMode::Monitor), enter_masc_panel)
            .add_systems(OnExit(ViewerMode::Monitor), exit_masc_panel)
            .add_systems(OnEnter(ViewerMode::Council), enter_masc_panel)
            .add_systems(OnExit(ViewerMode::Council), exit_masc_panel)
            .add_systems(OnEnter(ViewerMode::Social), enter_masc_panel)
            .add_systems(OnExit(ViewerMode::Social), exit_masc_panel)
            .add_systems(OnEnter(ViewerMode::Experiment), enter_masc_panel)
            .add_systems(OnExit(ViewerMode::Experiment), exit_masc_panel)
            .add_systems(Update, refresh_trpg_widget_status.run_if(in_state(ViewerMode::Trpg)))
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

        let _ = el
            .dyn_ref::<web_sys::EventTarget>()
            .map(|target| target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));

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

    let _ = btn
        .dyn_ref::<web_sys::EventTarget>()
        .map(|target| target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));

    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn set_debug_state(doc: &web_sys::Document, enabled: bool) {
    if let Some(dashboard) = doc.get_element_by_id("dashboard") {
        let _ = dashboard.set_attribute("data-debug", if enabled { "on" } else { "off" });
    }
    if let Some(toggle) = doc.get_element_by_id("debug-log-toggle") {
        toggle.set_text_content(Some(if enabled { "Debug ON" } else { "Debug OFF" }));
        let _ = toggle.set_attribute("aria-pressed", if enabled { "true" } else { "false" });
    }
    if let Some(status) = doc.get_element_by_id("debug-log-status") {
        status.set_text_content(Some(if enabled { "DEBUG ON" } else { "DEBUG OFF" }));
    }
}

#[cfg(target_arch = "wasm32")]
fn bind_debug_controls(doc: &web_sys::Document) {
    let Some(toggle) = doc.get_element_by_id("debug-log-toggle") else {
        return;
    };
    if toggle.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = toggle.set_attribute("data-bound", "1");
    set_debug_state(doc, true);

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

    let _ = toggle
        .dyn_ref::<web_sys::EventTarget>()
        .map(|target| target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));

    cb.forget();
}

fn refresh_trpg_widget_status() {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let narrative_count = doc
            .get_element_by_id("narrative-log")
            .map(|el| el.child_element_count())
            .unwrap_or(0);
        let party_count = doc
            .get_element_by_id("character-panel")
            .map(|el| el.child_element_count())
            .unwrap_or(0);
        let dice_count = doc
            .get_element_by_id("dice-log")
            .map(|el| el.child_element_count())
            .unwrap_or(0);
        if let Some(status) = doc.get_element_by_id("widget-status") {
            status.set_text_content(Some(&format!(
                "Widgets N:{} P:{} D:{}",
                narrative_count, party_count, dice_count
            )));
        }
    }
}

// ─── Generic MASC Panel Enter/Exit ───────────

/// Generic enter handler for MASC mode panels (Monitor, Council, Social, Experiment).
/// Shows the mode's panel, hides lobby and dashboard, binds back navigation.
fn enter_masc_panel(mode: Res<State<ViewerMode>>, buffer: Res<ModeTransitionBuffer>) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(panel_id) = mode.get().panel_id() else { return };
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else { return };

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
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else { return };
        for panel_id in &["monitor-panel", "council-panel", "social-panel", "experiment-panel"] {
            set_panel_active(&doc, panel_id, false);
        }
    }
}

// ─── DOM Helpers ─────────────────────────────

/// Helper to set display style on a DOM element by ID.
/// Used for lobby-screen (flex) and dashboard (grid/none) which don't use CSS transitions.
#[cfg(target_arch = "wasm32")]
fn set_element_display(doc: &web_sys::Document, id: &str, display: &str) {
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
}
