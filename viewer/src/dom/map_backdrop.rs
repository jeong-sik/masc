use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;

#[cfg(target_arch = "wasm32")]
use crate::assets;
use crate::game::state::MapState;

/// Cache to avoid redundant DOM writes for map backdrop updates.
#[derive(Resource, Debug, Default)]
pub struct MapBackdropCache {
    pub last_area: String,
    pub last_label: String,
}

fn normalize_area(raw: &str) -> &str {
    let trimmed = raw.trim();
    if trimmed.is_empty() { "A" } else { trimmed }
}

#[cfg(target_arch = "wasm32")]
fn map_asset_path(area: &str) -> String {
    let relative = assets::map_for(area).unwrap_or(assets::paths::MAP_AREA_A);
    format!("assets/{relative}")
}

/// Syncs current map area/label into DOM fallback view (wasm).
///
/// In wasm fallback mode we intentionally skip Bevy map rendering for stability.
/// This keeps the primary panel visually in sync by painting map images via CSS.
pub fn update_map_backdrop_dom(map_state: Res<MapState>, mut cache: ResMut<MapBackdropCache>) {
    let area = normalize_area(&map_state.current_area);
    let label = if map_state.area_label.trim().is_empty() {
        format!("AREA {area}")
    } else {
        map_state.area_label.trim().to_string()
    };

    if area == cache.last_area && label == cache.last_label {
        return;
    }

    #[cfg(target_arch = "wasm32")]
    {
        let Some(document) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        let image_path = map_asset_path(area);
        let composed_bg = format!(
            "linear-gradient(rgba(3, 6, 14, 0.45), rgba(3, 6, 14, 0.62)), url('{image_path}')"
        );

        if let Some(primary_zone) = document
            .get_element_by_id("primary-zone")
            .and_then(|el| el.dyn_into::<web_sys::HtmlElement>().ok())
        {
            let style = primary_zone.style();
            let _ = style.set_property("background-image", &composed_bg);
            let _ = style.set_property("background-size", "cover");
            let _ = style.set_property("background-position", "center center");
            let _ = style.set_property("background-repeat", "no-repeat");
        }

        if let Some(canvas) = document
            .get_element_by_id("bevy-canvas")
            .and_then(|el| el.dyn_into::<web_sys::HtmlElement>().ok())
        {
            let style = canvas.style();
            let _ = style.set_property("display", "none");
        }

        if let Some(label_el) = document.get_element_by_id("map-label") {
            label_el.set_text_content(Some(&label));
        }
    }

    cache.last_area = area.to_string();
    cache.last_label = label;
}
