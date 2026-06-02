use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;

use crate::game::state::{ChoiceState, CombatState, OverlayState, WorkspaceState};

#[cfg(target_arch = "wasm32")]
use super::escape::html_escape;

/// Cache to avoid redundant DOM writes.
#[derive(Resource, Debug, Default)]
pub struct OverlayCache {
    pub last_weather: String,
    pub last_mood: String,
    pub last_choice_active: bool,
    pub last_combat_active: bool,
    pub last_scenario: String,
    pub last_node: String,
}

#[cfg(target_arch = "wasm32")]
fn pretty_label(raw: &str) -> String {
    raw.split('_')
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => format!("{}{}", first.to_ascii_uppercase(), chars.as_str()),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(target_arch = "wasm32")]
fn weather_icon_path(id: &str) -> Option<&'static str> {
    match id {
        "drizzle" => Some("/assets/weather/weather_drizzle.png"),
        "heavy_rain" => Some("/assets/weather/weather_heavy_rain.png"),
        "fog" => Some("/assets/weather/weather_fog.png"),
        "silence" => Some("/assets/weather/weather_silence.png"),
        _ => None,
    }
}

#[cfg(target_arch = "wasm32")]
fn mood_icon_path(id: &str) -> Option<&'static str> {
    match id {
        "quiet_unease" => Some("/assets/moods/mood_quiet_unease.png"),
        "tension_rising" => Some("/assets/moods/mood_tension_rising.png"),
        "ambiguous_calm" => Some("/assets/moods/mood_ambiguous_calm.png"),
        _ => None,
    }
}

/// Sync OverlayState, ChoiceState, and CombatState to DOM elements.
///
/// Expected HTML elements:
/// - `#weather-indicator` — weather text
/// - `#mood-indicator` — mood/atmosphere text
/// - `#choice-overlay` — choice panel (hidden when inactive)
/// - `#combat-overlay` — combat indicator (hidden when inactive)
/// - `#scene-indicator` — current scenario and node display
#[allow(unused_mut)]
#[allow(unused_variables)]
pub fn update_overlay_dom(
    overlay: Res<OverlayState>,
    choice: Res<ChoiceState>,
    combat: Res<CombatState>,
    workspace_state: Res<WorkspaceState>,
    mut cache: ResMut<OverlayCache>,
) {
    let weather_changed = overlay.weather != cache.last_weather;
    let mood_changed = overlay.mood != cache.last_mood;
    let choice_changed = choice.active != cache.last_choice_active;
    let combat_changed = combat.active != cache.last_combat_active;
    let scene_changed = workspace_state.current_scenario != cache.last_scenario
        || workspace_state.current_node != cache.last_node;

    if weather_changed || mood_changed || choice_changed || combat_changed || scene_changed {
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
                        el.set_text_content(Some(&pretty_label(&overlay.weather)));
                    }
                }
                if let Some(img) = document
                    .get_element_by_id("weather-icon")
                    .and_then(|el| el.dyn_into::<web_sys::HtmlImageElement>().ok())
                {
                    if let Some(path) = weather_icon_path(overlay.weather.trim()) {
                        img.set_src(path);
                        img.set_alt(&pretty_label(&overlay.weather));
                        let _ = img.set_attribute("data-empty", "0");
                    } else {
                        let _ = img.remove_attribute("src");
                        img.set_alt("");
                        let _ = img.set_attribute("data-empty", "1");
                    }
                }
                cache.last_weather = overlay.weather.clone();
            }

            if mood_changed {
                if let Some(el) = document.get_element_by_id("mood-indicator") {
                    if overlay.mood.is_empty() {
                        el.set_text_content(None);
                    } else {
                        el.set_text_content(Some(&pretty_label(&overlay.mood)));
                    }
                }
                if let Some(img) = document
                    .get_element_by_id("mood-icon")
                    .and_then(|el| el.dyn_into::<web_sys::HtmlImageElement>().ok())
                {
                    if let Some(path) = mood_icon_path(overlay.mood.trim()) {
                        img.set_src(path);
                        img.set_alt(&pretty_label(&overlay.mood));
                        let _ = img.set_attribute("data-empty", "0");
                    } else {
                        let _ = img.remove_attribute("src");
                        img.set_alt("");
                        let _ = img.set_attribute("data-empty", "1");
                    }
                }
                cache.last_mood = overlay.mood.clone();
            }

            if choice_changed {
                if let Some(el) = document.get_element_by_id("choice-overlay") {
                    if choice.active {
                        let html = format!(
                            "<strong>{}</strong><p>{}</p><ul>{}</ul>",
                            html_escape(&choice.character),
                            html_escape(&choice.description),
                            choice
                                .options
                                .iter()
                                .map(|o| format!("<li>{}</li>", html_escape(o)))
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
                            html_escape(&combat.area),
                            html_escape(&enemies_str)
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

            if scene_changed {
                if let Some(el) = document.get_element_by_id("scene-indicator") {
                    let scenario = workspace_state.current_scenario.trim();
                    let node = workspace_state.current_node.trim();
                    if scenario.is_empty() && node.is_empty() {
                        el.set_text_content(None);
                        if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
                            let _ = html_el.style().set_property("display", "none");
                        }
                    } else {
                        let label = if node.is_empty() {
                            pretty_label(scenario)
                        } else {
                            format!("{} — {}", pretty_label(scenario), pretty_label(node))
                        };
                        el.set_text_content(Some(&label));
                        if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
                            let _ = html_el.style().set_property("display", "block");
                        }
                    }
                }
                cache.last_scenario = workspace_state.current_scenario.clone();
                cache.last_node = workspace_state.current_node.clone();
            }
        }
    }
}
