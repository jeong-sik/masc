//! Viewer mode state machine.
//!
//! Each mode represents a distinct visualization context within the MASC viewer.
//! Bevy's `States` derive gates system execution per mode — TRPG systems only
//! run in `ViewerMode::Trpg`, monitor systems only in `ViewerMode::Monitor`, etc.

use bevy::prelude::*;
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
    /// SSE: TRPG Engine `/rooms/:id/stream`
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

    /// Short description shown in the lobby mode selector.
    pub fn description(&self) -> &'static str {
        match self {
            Self::Lobby => "Select a visualization mode",
            Self::Trpg => "Dark fantasy TRPG — 5 AI agents play D&D 5e",
            Self::Experiment => "Live experiment metrics and flow visualization",
            Self::Monitor => "Agent health, keeper metrics, system dashboard",
            Self::Council => "MAGI deliberation — consensus and debate viewer",
            Self::Social => "Lodge social feed — posts, votes, discussions",
        }
    }

    /// All selectable modes (excludes Lobby itself).
    pub fn selectable() -> &'static [ViewerMode] {
        &[
            Self::Trpg,
            Self::Experiment,
            Self::Monitor,
            Self::Council,
            Self::Social,
        ]
    }

    /// CSS class name applied to the HTML body for mode-specific DOM styling.
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
}

/// Plugin that registers the ViewerMode state and mode transition systems.
pub struct ModePlugin;

impl Plugin for ModePlugin {
    fn build(&self, app: &mut App) {
        app.init_state::<ViewerMode>()
            .add_systems(OnEnter(ViewerMode::Lobby), on_enter_lobby)
            .add_systems(OnExit(ViewerMode::Lobby), on_exit_lobby);
    }
}

/// Startup logic when entering Lobby mode.
fn on_enter_lobby() {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            // Show lobby UI, hide mode-specific panels
            if let Some(body) = doc.body() {
                body.set_class_name("mode-lobby");
            }
            set_element_display(&doc, "lobby-screen", "flex");
            set_element_display(&doc, "dashboard", "none");
        }
    }
}

/// Cleanup when leaving Lobby mode (entering a visualization mode).
fn on_exit_lobby() {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            set_element_display(&doc, "lobby-screen", "none");
            set_element_display(&doc, "dashboard", "grid");
        }
    }
}

/// Helper to set display style on a DOM element by ID.
#[cfg(target_arch = "wasm32")]
fn set_element_display(doc: &web_sys::Document, id: &str, display: &str) {
    if let Some(el) = doc.get_element_by_id(id) {
        if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
            let _ = html_el.style().set_property("display", display);
        }
    }
}
