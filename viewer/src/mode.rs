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

    /// Parse from the HTML `data-mode` attribute value.
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

// ─── DOM Helpers ─────────────────────────────

/// Helper to set display style on a DOM element by ID.
#[cfg(target_arch = "wasm32")]
fn set_element_display(doc: &web_sys::Document, id: &str, display: &str) {
    if let Some(el) = doc.get_element_by_id(id) {
        if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
            let _ = html_el.style().set_property("display", display);
        }
    }
}
