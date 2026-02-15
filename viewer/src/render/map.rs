use bevy::prelude::*;

use crate::game::components::GameCamera;
use crate::game::state::MapState;
use crate::shaders::PostProcessSettings;

/// Map area → screen position mapping.
/// Areas A-F are zones within the current scenario map.
pub fn area_to_position(area: &str) -> Vec2 {
    match area {
        "A" => Vec2::new(-300.0, 150.0),
        "B" => Vec2::new(-100.0, 150.0),
        "C" => Vec2::new(100.0, 0.0),
        "D" => Vec2::new(-200.0, -100.0),
        "E" => Vec2::new(0.0, -150.0),
        "F" => Vec2::new(250.0, -100.0),
        _ => Vec2::ZERO,
    }
}

/// Spawns the 2D camera.
pub fn setup_camera(mut commands: Commands) {
    commands.spawn((
        Camera2d,
        GameCamera,
        PostProcessSettings {
            kuwahara_radius: 3.0,
            edge_strength: 0.6,
            saturation: 0.75,
            warmth: 0.8,
            vignette_strength: 0.4,
            grain_strength: 0.03,
            time: 0.0,
            intensity: 1.0,
        },
    ));
}

/// Spawns a placeholder map background.
/// In Phase F, this will be replaced with AI-generated area art.
pub fn setup_map_background(mut commands: Commands) {
    // Dark background sprite as map placeholder
    commands.spawn((
        Sprite {
            color: Color::srgb(0.06, 0.06, 0.10),
            custom_size: Some(Vec2::new(1280.0, 720.0)),
            ..default()
        },
        Transform::from_xyz(0.0, 0.0, -10.0),
    ));
}

/// Updates the map label overlay when the area changes.
pub fn update_map_label(map_state: Res<MapState>) {
    if !map_state.is_changed() {
        return;
    }

    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(label) = document.get_element_by_id("map-label") else {
        return;
    };

    let area_text = if map_state.area_label.is_empty() {
        format!("AREA {}", map_state.current_area)
    } else {
        map_state.area_label.clone()
    };

    label.set_text_content(Some(&area_text));
}
