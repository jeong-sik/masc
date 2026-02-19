use bevy::prelude::*;

use super::map::{area_to_position, position_to_area};
use crate::assets;
use crate::game::components::*;

/// Marker component for entities that can be dragged by the player.
#[derive(Component)]
pub struct Draggable;

/// Tracks the current drag state.
#[derive(Resource, Default)]
pub struct DragState {
    pub dragged_entity: Option<Entity>,
    pub drag_offset: Vec2,
}

/// Character color assignments — each party member gets a distinct color.
/// Used as fallback tint when portrait texture is not yet loaded.
fn character_color(id: &str) -> Color {
    match id {
        // Grimland originals
        "grimja" => Color::srgb(0.8, 0.3, 0.2), // warrior red
        "luna" => Color::srgb(0.3, 0.4, 0.8),   // mage blue
        "songarak" => Color::srgb(0.3, 0.7, 0.3), // rogue green
        "miso" => Color::srgb(0.8, 0.7, 0.3),   // cleric gold
        // Identity Erosion
        "iron" => Color::srgb(0.9, 0.9, 0.85), // ivory white (uncanny saint)
        "moth" => Color::srgb(0.4, 0.3, 0.5),  // murky purple (J-horror)
        "bell" => Color::srgb(1.0, 0.85, 0.3), // bright gold (cult leader glow)
        "dust" => Color::srgb(0.4, 0.4, 0.35), // muted brown-grey (shrinking)
        // Conformity Pressure
        "aldric" => Color::srgb(0.6, 0.2, 0.15), // dark crimson (authority)
        "brenna" => Color::srgb(0.7, 0.55, 0.4), // warm tan (agreeable)
        "cedric" => Color::srgb(0.5, 0.6, 0.7),  // pale blue (uncertain)
        "dara" => Color::srgb(0.5, 0.45, 0.55),  // sage purple (observer)
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
            Draggable,
        ));

        // HP bar as child entity (positioned below the sprite)
        let hp_bar = commands
            .spawn((
                Sprite {
                    color: Color::srgb(0.2, 0.7, 0.2),
                    custom_size: Some(Vec2::new(36.0, 3.0)),
                    ..default()
                },
                Transform::from_xyz(0.0, -38.0, 0.1),
                HpBarSprite { max_width: 36.0 },
            ))
            .id();

        commands.entity(entity).add_child(hp_bar);
    }
}

/// Updates character positions when they move between areas.
pub fn update_character_positions(mut actors: Query<(&Actor, &mut Transform), With<MapToken>>) {
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

/// Handles drag start - captures entity and offset.
#[allow(clippy::type_complexity)]
pub fn handle_drag_start(
    mut drag_state: ResMut<DragState>,
    windows: Query<&Window>,
    camera_query: Query<(&Camera, &GlobalTransform), With<GameCamera>>,
    mut query: Query<(Entity, &Transform), (With<Draggable>, Without<ChildOf>)>,
    mouse_button_input: Res<ButtonInput<MouseButton>>,
) {
    if !mouse_button_input.just_pressed(MouseButton::Left) {
        return;
    }

    let Ok(window) = windows.single() else {
        return;
    };
    let Some(cursor_pos) = window.cursor_position() else {
        return;
    };

    // Project screen cursor to world space via the game camera
    let Ok((camera, camera_transform)) = camera_query.single() else {
        return;
    };
    let Ok(world_pos) = camera.viewport_to_world_2d(camera_transform, cursor_pos) else {
        return;
    };

    for (entity, transform) in &mut query {
        let entity_pos = Vec2::new(transform.translation.x, transform.translation.y);
        let size = 32.0; // Approximate token size

        let diff = world_pos - entity_pos;
        if diff.x.abs() < size && diff.y.abs() < size {
            drag_state.dragged_entity = Some(entity);
            drag_state.drag_offset = entity_pos - world_pos;
            log::info!("Drag started: entity {:?}", entity);
            break;
        }
    }
}

/// Handles drag movement - updates entity position.
pub fn handle_drag(
    mut drag_state: ResMut<DragState>,
    windows: Query<&Window>,
    camera_query: Query<(&Camera, &GlobalTransform), With<GameCamera>>,
    mut query: Query<&mut Transform, With<Draggable>>,
    mouse_button_input: Res<ButtonInput<MouseButton>>,
) {
    let Some(entity) = drag_state.dragged_entity else {
        return;
    };

    if !mouse_button_input.pressed(MouseButton::Left) {
        drag_state.dragged_entity = None;
        return;
    }

    let Ok(mut transform) = query.get_mut(entity) else {
        drag_state.dragged_entity = None;
        return;
    };

    let Ok(window) = windows.single() else {
        return;
    };
    let Some(cursor_pos) = window.cursor_position() else {
        return;
    };

    let Ok((camera, camera_transform)) = camera_query.single() else {
        return;
    };
    let Ok(world_pos) = camera.viewport_to_world_2d(camera_transform, cursor_pos) else {
        return;
    };

    let new_pos = world_pos + drag_state.drag_offset;
    transform.translation.x = new_pos.x;
    transform.translation.y = new_pos.y;
}

/// Handles drag end - updates Actor area based on final position.
pub fn handle_drag_end(
    mut drag_state: ResMut<DragState>,
    mut actors: Query<&mut Actor>,
    mouse_button_input: Res<ButtonInput<MouseButton>>,
    map_query: Query<&Transform, (With<MapToken>, With<Draggable>)>,
) {
    if !mouse_button_input.just_released(MouseButton::Left) {
        return;
    }

    let Some(entity) = drag_state.dragged_entity else {
        return;
    };

    let Ok(transform) = map_query.get(entity) else {
        drag_state.dragged_entity = None;
        return;
    };

    let final_pos = Vec2::new(transform.translation.x, transform.translation.y);

    // Snap to nearest named area using the same coordinate system as area_to_position
    if let Ok(mut actor) = actors.get_mut(entity) {
        actor.area = position_to_area(final_pos);
        log::info!(
            "Drag ended: entity {:?} moved to area {}",
            entity,
            actor.area
        );
    }

    drag_state.dragged_entity = None;
}

/// Applies grayscale effect to dead actors.
#[allow(clippy::type_complexity)]
pub fn apply_death_visuals(
    mut actors: Query<(&Actor, &mut Sprite), (With<MapToken>, Changed<Actor>)>,
) {
    for (actor, mut sprite) in &mut actors {
        if actor.is_dead {
            sprite.color = Color::srgb(0.3, 0.3, 0.3);
        }
    }
}
