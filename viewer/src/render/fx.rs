use bevy::prelude::*;

use crate::game::components::FloatingText;
use crate::game::events::HpChanged;

/// Spawns a floating damage/heal number above the affected character.
pub fn spawn_damage_text(
    mut commands: Commands,
    mut hp_events: MessageReader<HpChanged>,
) {
    for HpChanged(payload) in hp_events.read() {
        let color = if payload.amount < 0 {
            Color::srgb(0.9, 0.2, 0.1) // damage = red
        } else {
            Color::srgb(0.2, 0.8, 0.3) // heal = green
        };

        let text = if payload.amount < 0 {
            format!("{}", payload.amount)
        } else {
            format!("+{}", payload.amount)
        };

        // Spawn at a position that will be overridden if we find the actor
        // For now, spawn at origin — Phase D will position relative to actor
        commands.spawn((
            Text2d::new(text),
            TextFont {
                font_size: 24.0,
                ..default()
            },
            TextColor(color),
            Transform::from_xyz(0.0, 40.0, 10.0),
            FloatingText {
                timer: Timer::from_seconds(1.5, TimerMode::Once),
                velocity: Vec2::new(0.0, 30.0),
            },
        ));
    }
}

/// Animates floating text upward and fades it out.
pub fn animate_floating_text(
    mut commands: Commands,
    time: Res<Time>,
    mut texts: Query<(Entity, &mut Transform, &mut TextColor, &mut FloatingText)>,
) {
    for (entity, mut transform, mut color, mut floating) in &mut texts {
        floating.timer.tick(time.delta());

        // Move upward
        transform.translation.y += floating.velocity.y * time.delta_secs();

        // Fade out based on timer progress
        let alpha = 1.0 - floating.timer.fraction();
        color.0 = color.0.with_alpha(alpha);

        // Despawn when done
        if floating.timer.just_finished() {
            commands.entity(entity).despawn();
        }
    }
}
