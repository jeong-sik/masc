use bevy::prelude::*;

use crate::assets;
use crate::game::components::*;
use super::map::area_to_position;

/// Character color assignments — each party member gets a distinct color.
fn character_color(id: &str) -> Color {
    match id {
        "grimja" => Color::srgb(0.8, 0.3, 0.2),    // warrior red
        "luna" => Color::srgb(0.3, 0.4, 0.8),       // mage blue
        "songarak" => Color::srgb(0.3, 0.7, 0.3),   // rogue green
        "miso" => Color::srgb(0.8, 0.7, 0.3),       // cleric gold
        _ => Color::srgb(0.6, 0.6, 0.6),
    }
}

/// Spawns character token sprites from Actor components that lack MapToken.
/// Uses AI-generated portrait textures when available, falls back to colored squares.
pub fn spawn_character_sprites(
    mut commands: Commands,
    asset_server: Res<AssetServer>,
    actors: Query<(Entity, &Actor), Without<MapToken>>,
) {
    for (entity, actor) in &actors {
        let pos = area_to_position(&actor.area);

        // Use portrait texture if available, fallback to colored square
        let sprite = if let Some(path) = assets::portrait_for(&actor.id) {
            Sprite {
                image: asset_server.load(path),
                custom_size: Some(Vec2::new(64.0, 64.0)),
                ..default()
            }
        } else {
            Sprite {
                color: character_color(&actor.id),
                custom_size: Some(Vec2::new(40.0, 40.0)),
                ..default()
            }
        };

        commands.entity(entity).insert((
            sprite,
            Transform::from_xyz(pos.x, pos.y, 1.0),
            MapToken,
        ));

        // HP bar as child entity (positioned below the sprite)
        let hp_bar = commands.spawn((
            Sprite {
                color: Color::srgb(0.2, 0.7, 0.2),
                custom_size: Some(Vec2::new(36.0, 3.0)),
                ..default()
            },
            Transform::from_xyz(0.0, -38.0, 0.1),
            HpBarSprite { max_width: 36.0 },
        )).id();

        commands.entity(entity).add_child(hp_bar);
    }
}

/// Updates character positions when they move between areas.
pub fn update_character_positions(
    mut actors: Query<(&Actor, &mut Transform), With<MapToken>>,
) {
    for (actor, mut transform) in &mut actors {
        let target = area_to_position(&actor.area);
        // Lerp toward target position for smooth movement
        let current = Vec2::new(transform.translation.x, transform.translation.y);
        let new_pos = current.lerp(target, 0.1);
        transform.translation.x = new_pos.x;
        transform.translation.y = new_pos.y;
    }
}

/// Updates HP bar width based on current HP.
pub fn update_hp_bars(
    actors: Query<(&Actor, &Children), With<MapToken>>,
    mut hp_bars: Query<(&mut Sprite, &HpBarSprite)>,
) {
    for (actor, children) in &actors {
        for child in children.iter() {

            if let Ok((mut sprite, hp_bar)) = hp_bars.get_mut(child) {
                let ratio = if actor.max_hp > 0 {
                    (actor.hp as f32 / actor.max_hp as f32).clamp(0.0, 1.0)
                } else {
                    0.0
                };

                sprite.custom_size = Some(Vec2::new(hp_bar.max_width * ratio, 3.0));

                // Color based on HP ratio
                sprite.color = if ratio > 0.6 {
                    Color::srgb(0.2, 0.7, 0.2)
                } else if ratio > 0.25 {
                    Color::srgb(0.8, 0.7, 0.1)
                } else {
                    Color::srgb(0.8, 0.2, 0.1)
                };
            }
        }
    }
}

/// Desaturates dead character sprites.
pub fn apply_death_visuals(
    mut actors: Query<(&Actor, &mut Sprite), (With<MapToken>, Changed<Actor>)>,
) {
    for (actor, mut sprite) in &mut actors {
        if actor.is_dead {
            sprite.color = Color::srgb(0.3, 0.3, 0.3);
        }
    }
}
