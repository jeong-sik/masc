use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;

use crate::game::state::{ChoiceState, CombatState, OverlayState};

/// Cache to avoid redundant DOM writes.
#[derive(Resource, Debug, Default)]
pub struct OverlayCache {
    pub last_weather: String,
    pub last_mood: String,
    pub last_choice_active: bool,
    pub last_combat_active: bool,
}

/// Sync OverlayState, ChoiceState, and CombatState to DOM elements.
///
/// Expected HTML elements:
/// - `#weather-indicator` — weather text
/// - `#mood-indicator` — mood/atmosphere text
/// - `#choice-overlay` — choice panel (hidden when inactive)
/// - `#combat-overlay` — combat indicator (hidden when inactive)
pub fn update_overlay_dom(
    overlay: Res<OverlayState>,
    choice: Res<ChoiceState>,
    combat: Res<CombatState>,
    mut cache: ResMut<OverlayCache>,
) {
    let weather_changed = overlay.weather != cache.last_weather;
    let mood_changed = overlay.mood != cache.last_mood;
    let choice_changed = choice.active != cache.last_choice_active;
    let combat_changed = combat.active != cache.last_combat_active;

    if !weather_changed && !mood_changed && !choice_changed && !combat_changed {
        return;
    }

    #[cfg(target_arch = "wasm32")]
    {
        let Some(document) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        if weather_changed {
            if let Some(el) = document.get_element_by_id("weather-indicator") {
                if overlay.weather.is_empty() {
                    el.set_text_content(None);
                } else {
                    el.set_text_content(Some(&overlay.weather));
                }
            }
            cache.last_weather = overlay.weather.clone();
        }

        if mood_changed {
            if let Some(el) = document.get_element_by_id("mood-indicator") {
                if overlay.mood.is_empty() {
                    el.set_text_content(None);
                } else {
                    el.set_text_content(Some(&overlay.mood));
                }
            }
            cache.last_mood = overlay.mood.clone();
        }

        if choice_changed {
            if let Some(el) = document.get_element_by_id("choice-overlay") {
                if choice.active {
                    let html = format!(
                        "<strong>{}</strong><p>{}</p><ul>{}</ul>",
                        choice.character,
                        choice.description,
                        choice
                            .options
                            .iter()
                            .map(|o| format!("<li>{}</li>", o))
                            .collect::<Vec<_>>()
                            .join("")
                    );
                    el.set_inner_html(&html);
                    if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
                        let _ = html_el.style().set_property("display", "block");
                    }
                } else {
                    el.set_inner_html("");
                    if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
                        let _ = html_el.style().set_property("display", "none");
                    }
                }
            }
            cache.last_choice_active = choice.active;
        }

        if combat_changed {
            if let Some(el) = document.get_element_by_id("combat-overlay") {
                if combat.active {
                    let enemies_str = combat.enemies.join(", ");
                    let html = format!(
                        "<strong>COMBAT</strong> <span>{}</span><p>{}</p>",
                        combat.area, enemies_str
                    );
                    el.set_inner_html(&html);
                    if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
                        let _ = html_el.style().set_property("display", "block");
                    }
                } else {
                    el.set_inner_html("");
                    if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
                        let _ = html_el.style().set_property("display", "none");
                    }
                }
            }
            cache.last_combat_active = combat.active;
        }
    }
}
