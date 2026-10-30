use bevy::prelude::*;

use crate::game::events::AreaMoved;
use crate::game::state::MapState;

/// Resource tracking an active scene transition (fade to black and back).
#[derive(Resource, Default)]
pub struct SceneTransition {
    pub active: bool,
    pub timer: Timer,
    /// 0.0 = fully visible, 1.0 = fully black
    pub alpha: f32,
    pub target_area: String,
    /// Phase: true = fading out, false = fading in
    pub fading_out: bool,
}

/// Marker for the full-screen fade overlay sprite.
#[derive(Component)]
pub struct FadeOverlay;

/// Spawns the fade overlay (initially invisible), sized to cover the window.
pub fn setup_fade_overlay(mut commands: Commands, windows: Query<&Window>) {
    let size = windows
        .single()
        .map_or(Vec2::new(2000.0, 2000.0), |win: &Window| {
            Vec2::new(win.width() * 1.5, win.height() * 1.5)
        });
    commands.spawn((
        Sprite {
            color: Color::srgba(0.0, 0.0, 0.0, 0.0),
            custom_size: Some(size),
            ..default()
        },
        Transform::from_xyz(0.0, 0.0, 50.0), // Above everything
        FadeOverlay,
    ));
}

/// Triggers a scene transition when an area_move event is received.
pub fn trigger_scene_transition(
    mut events: MessageReader<AreaMoved>,
    mut transition: ResMut<SceneTransition>,
) {
    for AreaMoved(payload) in events.read() {
        if !transition.active {
            transition.active = true;
            transition.fading_out = true;
            transition.alpha = 0.0;
            transition.timer = Timer::from_seconds(0.4, TimerMode::Once);
            transition.target_area = payload.to_area.clone();
        }
    }
}

/// Animates the fade overlay and updates map state at the midpoint.
pub fn animate_scene_transition(
    time: Res<Time>,
    mut transition: ResMut<SceneTransition>,
    mut map_state: ResMut<MapState>,
    mut overlays: Query<&mut Sprite, With<FadeOverlay>>,
) {
    if !transition.active {
        return;
    }

    transition.timer.tick(time.delta());
    let progress = transition.timer.fraction();

    if transition.fading_out {
        transition.alpha = progress;

        if transition.timer.just_finished() {
            // Midpoint: swap the map
            map_state.current_area = transition.target_area.clone();
            // Start fading back in
            transition.fading_out = false;
            transition.timer = Timer::from_seconds(0.4, TimerMode::Once);
        }
    } else {
        transition.alpha = 1.0 - progress;

        if transition.timer.just_finished() {
            transition.active = false;
            transition.alpha = 0.0;
        }
    }

    // Apply alpha to overlay sprite
    for mut sprite in &mut overlays {
        sprite.color = Color::srgba(0.0, 0.0, 0.0, transition.alpha);
    }
}
