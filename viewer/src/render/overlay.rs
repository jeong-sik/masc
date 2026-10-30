use bevy::prelude::*;

use crate::assets;
use crate::game::components::{FloatingText, MapToken, MoodOverlay, WeatherOverlay};
use crate::game::events::ItemAcquired;
use crate::game::state::OverlayState;

/// Spawns the weather overlay sprite (full-screen, z = -9.0).
/// Starts fully transparent until a weather state is received via SSE.
pub fn setup_weather_overlay(mut commands: Commands) {
    commands.spawn((
        Sprite {
            color: Color::srgba(1.0, 1.0, 1.0, 0.0),
            custom_size: Some(Vec2::new(1280.0, 720.0)),
            ..default()
        },
        Transform::from_xyz(0.0, 0.0, -9.0),
        WeatherOverlay,
    ));
}

/// Spawns the mood overlay sprite (full-screen, z = -8.0).
/// Starts fully transparent until a mood state is received via SSE.
pub fn setup_mood_overlay(mut commands: Commands) {
    commands.spawn((
        Sprite {
            color: Color::srgba(1.0, 1.0, 1.0, 0.0),
            custom_size: Some(Vec2::new(1280.0, 720.0)),
            ..default()
        },
        Transform::from_xyz(0.0, 0.0, -8.0),
        MoodOverlay,
    ));
}

/// Swaps the weather overlay texture when `OverlayState.weather` changes.
pub fn update_weather_overlay(
    overlay_state: Res<OverlayState>,
    asset_server: Res<AssetServer>,
    mut overlays: Query<&mut Sprite, With<WeatherOverlay>>,
) {
    if !overlay_state.is_changed() {
        return;
    }

    for mut sprite in &mut overlays {
        if let Some(path) = assets::weather_for(&overlay_state.weather) {
            sprite.image = asset_server.load(path);
            sprite.color = Color::srgba(1.0, 1.0, 1.0, 0.6);
        } else {
            sprite.color = Color::srgba(1.0, 1.0, 1.0, 0.0);
        }
    }
}

/// Swaps the mood overlay texture when `OverlayState.mood` changes.
pub fn update_mood_overlay(
    overlay_state: Res<OverlayState>,
    asset_server: Res<AssetServer>,
    mut overlays: Query<&mut Sprite, With<MoodOverlay>>,
) {
    if !overlay_state.is_changed() {
        return;
    }

    for mut sprite in &mut overlays {
        if let Some(path) = assets::mood_for(&overlay_state.mood) {
            sprite.image = asset_server.load(path);
            sprite.color = Color::srgba(1.0, 1.0, 1.0, 0.4);
        } else {
            sprite.color = Color::srgba(1.0, 1.0, 1.0, 0.0);
        }
    }
}

/// Spawns a floating prop icon above the character when an item is acquired.
/// Reuses the `FloatingText` component so `fx::animate_floating_text` handles
/// the upward drift and despawn — no extra cleanup needed.
pub fn spawn_prop_notification(
    mut commands: Commands,
    mut events: MessageReader<ItemAcquired>,
    asset_server: Res<AssetServer>,
    actors: Query<(&crate::game::components::Actor, &Transform), With<MapToken>>,
) {
    for ItemAcquired(payload) in events.read() {
        let pos = actors
            .iter()
            .find(|(a, _)| a.id == payload.character)
            .map(|(_, t)| t.translation)
            .unwrap_or(Vec3::ZERO);

        if let Some(path) = assets::prop_for(&payload.item) {
            commands.spawn((
                Sprite {
                    image: asset_server.load(path),
                    custom_size: Some(Vec2::new(32.0, 32.0)),
                    ..default()
                },
                Transform::from_xyz(pos.x + 40.0, pos.y + 30.0, 2.0),
                FloatingText {
                    timer: Timer::from_seconds(2.0, TimerMode::Once),
                    velocity: Vec2::new(0.0, 20.0),
                },
            ));
        }
    }
}
