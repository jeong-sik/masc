use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use crate::assets;
use crate::game::state::MapState;

#[derive(Resource, Debug, Default)]
pub struct CanvasMapCache {
    #[cfg(target_arch = "wasm32")]
    pub last_area: String,
    #[cfg(target_arch = "wasm32")]
    pub last_label: String,
}

#[cfg(target_arch = "wasm32")]
pub fn update_canvas_map_dom(map_state: Res<MapState>, mut cache: ResMut<CanvasMapCache>) {
    use wasm_bindgen::JsCast;

    let area = map_state.current_area.trim();
    let normalized_area = if area.is_empty() { "A" } else { area };
    let label = if map_state.area_label.trim().is_empty() {
        format!("AREA {}", normalized_area)
    } else {
        map_state.area_label.trim().to_string()
    };

    if cache.last_area == normalized_area && cache.last_label == label {
        return;
    }

    let map_asset = assets::map_for(normalized_area).unwrap_or(assets::paths::MAP_AREA_A);
    let asset_url = format!("/assets/{}", map_asset);

    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };

    if let Some(canvas) = document
        .get_element_by_id("bevy-canvas")
        .and_then(|el| el.dyn_into::<web_sys::HtmlElement>().ok())
    {
        let style = canvas.style();
        let _ = style.set_property("background-image", &format!("url('{}')", asset_url));
        let _ = style.set_property("background-size", "cover");
        let _ = style.set_property("background-position", "center");
        let _ = style.set_property("background-repeat", "no-repeat");
        let _ = style.set_property("background-color", "#05070f");
    }

    if let Some(label_el) = document.get_element_by_id("map-label") {
        label_el.set_text_content(Some(&label));
    }

    cache.last_area = normalized_area.to_string();
    cache.last_label = label;
}

#[cfg(not(target_arch = "wasm32"))]
pub fn update_canvas_map_dom(_map_state: Res<MapState>, _cache: ResMut<CanvasMapCache>) {}
