use bevy::prelude::*;

use crate::game::components::{Actor, FloatingText, MapToken};
use crate::game::events::{CombatAttack, CombatDefense, HpChanged};

/// Spawns a floating damage/heal number above the affected character.
/// Looks up the actor's current Transform so the text appears on the token,
/// falling back to world origin if the actor is not found.
pub fn spawn_damage_text(
    mut commands: Commands,
    mut hp_events: MessageReader<HpChanged>,
    actors: Query<(&Actor, &Transform), With<MapToken>>,
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

        // Find the actor's position on the map; fall back to world origin
        let pos = actors
            .iter()
            .find(|(a, _)| a.id == payload.target)
            .map(|(_, t)| t.translation)
            .unwrap_or(Vec3::ZERO);

        commands.spawn((
            Text2d::new(text),
            TextFont {
                font_size: 24.0,
                ..default()
            },
            TextColor(color),
            Transform::from_xyz(pos.x, pos.y + 40.0, 10.0),
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

/// Spawns a floating attack label at the target position on CombatAttack events.
pub fn spawn_combat_attack_fx(
    mut commands: Commands,
    mut events: MessageReader<CombatAttack>,
    actors: Query<(&Actor, &Transform), With<MapToken>>,
) {
    for CombatAttack(payload) in events.read() {
        // Prefer target position; fall back to attacker position
        let pos = actors
            .iter()
            .find(|(a, _)| a.id == payload.target_id)
            .or_else(|| actors.iter().find(|(a, _)| a.id == payload.actor_id))
            .map(|(_, t)| t.translation)
            .unwrap_or(Vec3::ZERO);

        let label = if payload.action.is_empty() {
            "Attack".to_string()
        } else {
            payload.action.clone()
        };

        commands.spawn((
            Text2d::new(format!("\u{2694} {}", label)),
            TextFont {
                font_size: 20.0,
                ..default()
            },
            TextColor(Color::srgb(0.9, 0.3, 0.1)),
            Transform::from_xyz(pos.x, pos.y + 50.0, 10.0),
            FloatingText {
                timer: Timer::from_seconds(0.8, TimerMode::Once),
                velocity: Vec2::new(0.0, 25.0),
            },
        ));
    }
}

/// Spawns a floating defense label at the defender position on CombatDefense events.
pub fn spawn_combat_defense_fx(
    mut commands: Commands,
    mut events: MessageReader<CombatDefense>,
    actors: Query<(&Actor, &Transform), With<MapToken>>,
) {
    for CombatDefense(payload) in events.read() {
        let pos = actors
            .iter()
            .find(|(a, _)| a.id == payload.actor_id)
            .map(|(_, t)| t.translation)
            .unwrap_or(Vec3::ZERO);

        let label = if payload.method.is_empty() {
            "Defend".to_string()
        } else {
            payload.method.clone()
        };

        commands.spawn((
            Text2d::new(format!("\u{1F6E1} {}", label)),
            TextFont {
                font_size: 20.0,
                ..default()
            },
            TextColor(Color::srgb(0.3, 0.5, 0.9)),
            Transform::from_xyz(pos.x, pos.y + 50.0, 10.0),
            FloatingText {
                timer: Timer::from_seconds(0.8, TimerMode::Once),
                velocity: Vec2::new(0.0, 25.0),
            },
        ));
    }
}
