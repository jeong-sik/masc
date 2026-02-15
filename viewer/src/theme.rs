//! Visual theme presets for the MASC viewer.
//!
//! Themes control two layers simultaneously:
//! 1. **GPU shaders** — PostProcessSettings values (Kuwahara radius, color grading, etc.)
//! 2. **CSS variables** — DOM panel colors, fonts, borders via `data-theme` attribute
//!
//! Themes are a Resource (not a State) because switching themes should not
//! trigger entity despawn/respawn — only visual parameter changes.
//!
//! DOM `<select>` elements (`#theme-selector`, `#theme-selector-inline`) write to a
//! shared `ThemeTransitionBuffer`. A Bevy `Update` system polls the buffer and
//! updates the `ViewerTheme` resource, which triggers `apply_theme_changes`.

use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use std::sync::{Arc, Mutex};

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;

use crate::shaders::post_process::PostProcessSettings;

/// Active visual theme. Stored as a Bevy Resource for change detection.
#[derive(Resource, Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ViewerTheme {
    /// Disco Elysium oil painting — dark, moody, gothic. The original aesthetic.
    #[default]
    DarkFantasy,

    /// Neon-drenched cyberpunk — high contrast, chromatic aberration, glitch.
    Cyberpunk,

    /// Retro terminal — green phosphor on black, CRT scanlines, monospace.
    Terminal,

    /// Aged parchment — warm sepia tones, ink strokes, medieval manuscript.
    Parchment,
}

impl ViewerTheme {
    /// Human-readable display name.
    #[allow(dead_code)]
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::DarkFantasy => "Dark Fantasy",
            Self::Cyberpunk => "Cyberpunk",
            Self::Terminal => "Terminal",
            Self::Parchment => "Parchment",
        }
    }

    /// All available themes for the UI theme selector.
    #[allow(dead_code)]
    pub fn all() -> &'static [ViewerTheme] {
        &[
            Self::DarkFantasy,
            Self::Cyberpunk,
            Self::Terminal,
            Self::Parchment,
        ]
    }

    /// CSS `data-theme` attribute value applied to `<html>` element.
    /// CSS selectors: `[data-theme="dark-fantasy"] { --bg-deep: #0a0a12; ... }`
    pub fn css_value(&self) -> &'static str {
        match self {
            Self::DarkFantasy => "dark-fantasy",
            Self::Cyberpunk => "cyberpunk",
            Self::Terminal => "terminal",
            Self::Parchment => "parchment",
        }
    }

    /// Parse from the `<select>` option `value` attribute.
    pub fn from_css_value(s: &str) -> Option<ViewerTheme> {
        match s {
            "dark-fantasy" => Some(Self::DarkFantasy),
            "cyberpunk" => Some(Self::Cyberpunk),
            "terminal" => Some(Self::Terminal),
            "parchment" => Some(Self::Parchment),
            _ => None,
        }
    }

    /// PostProcessSettings preset for this theme's GPU shader parameters.
    pub fn shader_settings(&self) -> PostProcessSettings {
        match self {
            Self::DarkFantasy => PostProcessSettings {
                kuwahara_radius: 4.0,
                edge_strength: 0.3,
                saturation: 0.85,
                warmth: 0.15,
                vignette_strength: 0.4,
                grain_strength: 0.03,
                time: 0.0,
                intensity: 1.0,
            },
            Self::Cyberpunk => PostProcessSettings {
                kuwahara_radius: 2.0,
                edge_strength: 0.6,
                saturation: 1.4,
                warmth: -0.2,
                vignette_strength: 0.5,
                grain_strength: 0.05,
                time: 0.0,
                intensity: 0.8,
            },
            Self::Terminal => PostProcessSettings {
                kuwahara_radius: 1.0,
                edge_strength: 0.1,
                saturation: 0.0, // fully desaturated, CSS handles green tint
                warmth: -0.3,
                vignette_strength: 0.6,
                grain_strength: 0.08,
                time: 0.0,
                intensity: 0.5,
            },
            Self::Parchment => PostProcessSettings {
                kuwahara_radius: 3.0,
                edge_strength: 0.2,
                saturation: 0.7,
                warmth: 0.4,
                vignette_strength: 0.3,
                grain_strength: 0.02,
                time: 0.0,
                intensity: 0.9,
            },
        }
    }

    /// Background clear color for the Bevy canvas in this theme.
    pub fn clear_color(&self) -> Color {
        match self {
            Self::DarkFantasy => Color::srgb(0.04, 0.04, 0.07),   // #0a0a12
            Self::Cyberpunk => Color::srgb(0.02, 0.0, 0.06),      // deep indigo-black
            Self::Terminal => Color::srgb(0.0, 0.02, 0.0),        // near-black green
            Self::Parchment => Color::srgb(0.12, 0.10, 0.08),     // dark warm brown
        }
    }
}

// ─── Shared Buffer Resource ──────────────────

/// Holds pending theme transitions from JS change events.
/// The JS closure writes here; a Bevy Update system drains it.
#[derive(Resource)]
pub struct ThemeTransitionBuffer {
    #[cfg(target_arch = "wasm32")]
    pending: Arc<Mutex<Option<ViewerTheme>>>,
    #[cfg(not(target_arch = "wasm32"))]
    _phantom: (),
}

impl Default for ThemeTransitionBuffer {
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

/// Plugin that manages the viewer theme lifecycle.
pub struct ThemePlugin;

impl Plugin for ThemePlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<ViewerTheme>()
            .init_resource::<ThemeTransitionBuffer>()
            .add_systems(Startup, bind_theme_selectors)
            .add_systems(Update, (poll_theme_transition, apply_theme_changes));
    }
}

// ─── Theme Selector Binding ─────────────────

/// Startup system: binds change listeners to both theme `<select>` elements.
fn bind_theme_selectors(buffer: Res<ThemeTransitionBuffer>) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        // Bind both theme selectors (lobby + inline dashboard)
        for selector_id in &["theme-selector", "theme-selector-inline"] {
            bind_single_theme_selector(&doc, selector_id, &buffer.pending);
        }
    }

    let _ = &buffer;
}

/// Binds a `change` event listener to a single `<select>` element by ID.
#[cfg(target_arch = "wasm32")]
fn bind_single_theme_selector(
    doc: &web_sys::Document,
    id: &str,
    pending: &Arc<Mutex<Option<ViewerTheme>>>,
) {
    let Some(el) = doc.get_element_by_id(id) else {
        return;
    };
    let Some(select) = el.dyn_ref::<web_sys::HtmlSelectElement>() else {
        return;
    };

    let buf = pending.clone();
    let cb = Closure::wrap(Box::new(move |e: web_sys::Event| {
        let Some(target) = e.target() else { return };
        let Some(select_el) = target.dyn_ref::<web_sys::HtmlSelectElement>() else {
            return;
        };
        let value = select_el.value();
        if let Some(theme) = ViewerTheme::from_css_value(&value) {
            if let Ok(mut guard) = buf.lock() {
                *guard = Some(theme);
            }
        }
    }) as Box<dyn FnMut(web_sys::Event)>);

    let _ = select
        .dyn_ref::<web_sys::EventTarget>()
        .map(|target| {
            target.add_event_listener_with_callback("change", cb.as_ref().unchecked_ref())
        });

    cb.forget(); // Lives for app lifetime
}

// ─── Theme Transition Polling ───────────────

/// Polls the shared buffer each frame. When a theme selector changes,
/// updates the `ViewerTheme` resource (which triggers `apply_theme_changes`).
fn poll_theme_transition(
    buffer: Res<ThemeTransitionBuffer>,
    mut theme: ResMut<ViewerTheme>,
) {
    #[cfg(target_arch = "wasm32")]
    {
        let requested = {
            let Ok(mut buf) = buffer.pending.lock() else {
                return;
            };
            buf.take()
        };

        if let Some(new_theme) = requested {
            if *theme != new_theme {
                log::info!("Theme transition: {:?} → {:?}", *theme, new_theme);
                *theme = new_theme;

                // Sync both selectors to the new value
                if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
                    sync_theme_selectors(&doc, new_theme.css_value());
                }
            }
        }
    }

    let _ = (&buffer, &mut theme);
}

/// Keeps both `<select>` elements in sync when theme changes.
#[cfg(target_arch = "wasm32")]
fn sync_theme_selectors(doc: &web_sys::Document, css_value: &str) {
    for id in &["theme-selector", "theme-selector-inline"] {
        if let Some(el) = doc.get_element_by_id(id) {
            if let Some(select) = el.dyn_ref::<web_sys::HtmlSelectElement>() {
                select.set_value(css_value);
            }
        }
    }
}

// ─── Theme Application ──────────────────────

/// Reacts to theme changes by updating shader settings, clear color, and DOM attributes.
fn apply_theme_changes(
    theme: Res<ViewerTheme>,
    mut clear_color: ResMut<ClearColor>,
    mut cameras: Query<&mut PostProcessSettings>,
) {
    if !theme.is_changed() {
        return;
    }

    // Update GPU shader parameters
    let settings = theme.shader_settings();
    for mut cam_settings in &mut cameras {
        // Preserve the animated `time` field, override everything else
        let current_time = cam_settings.time;
        *cam_settings = settings;
        cam_settings.time = current_time;
    }

    // Update Bevy clear color
    clear_color.0 = theme.clear_color();

    // Update DOM theme attribute
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(html) = doc.document_element() {
                let _ = html.set_attribute("data-theme", theme.css_value());
            }
        }
    }
}
