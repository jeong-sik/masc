use bevy::prelude::*;

use crate::assets;
use crate::game::components::{GameCamera, MapBackground};
use crate::game::state::MapState;
use crate::theme::ViewerTheme;

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

/// Spawns the 2D camera with shader settings from the active theme.
pub fn setup_camera(mut commands: Commands, theme: Res<ViewerTheme>) {
    commands.spawn((
        Camera2d,
        GameCamera,
        theme.shader_settings(),
    ));
}

/// Spawns the map background with AI-generated area art.
pub fn setup_map_background(
    mut commands: Commands,
    asset_server: Res<AssetServer>,
    map_state: Res<MapState>,
) {
    let path = assets::map_for(&map_state.current_area)
        .unwrap_or(assets::paths::MAP_AREA_A);
    let texture = asset_server.load(path);
    commands.spawn((
        Sprite {
            image: texture,
            custom_size: Some(Vec2::new(1280.0, 720.0)),
            ..default()
        },
        Transform::from_xyz(0.0, 0.0, -10.0),
        MapBackground,
    ));
}

/// Updates the map label overlay when the area changes.
#[cfg(target_arch = "wasm32")]
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

/// Native no-op for update_map_label.
#[cfg(not(target_arch = "wasm32"))]
pub fn update_map_label(_map_state: Res<MapState>) {}

/// Swaps the map background texture when the current area changes.
pub fn update_map_texture(
    map_state: Res<MapState>,
    asset_server: Res<AssetServer>,
    mut backgrounds: Query<&mut Sprite, With<MapBackground>>,
) {
    if !map_state.is_changed() {
        return;
    }

    let path = assets::map_for(&map_state.current_area)
        .unwrap_or(assets::paths::MAP_AREA_A);

    for mut sprite in &mut backgrounds {
        sprite.image = asset_server.load(path);
    }
}
