pub mod characters;
pub mod fx;
pub mod map;
pub mod overlay;
pub mod transition;
pub mod ui;

use bevy::prelude::*;

use crate::game::components::{
    FloatingText, GameCamera, HpBarSprite, MapBackground, MapToken, MoodOverlay, WeatherOverlay,
};
use crate::render::ui::UiMarker;
use crate::render::characters::DragState;
use crate::mode::ViewerMode;
use crate::render::transition::{FadeOverlay, SceneTransition};

/// Plugin for 2D scene rendering: map backgrounds, character tokens, HP bars, effects.
///
/// Setup systems run on `OnEnter(Trpg)` — camera, map, and overlays are created
/// when entering TRPG mode. Update systems are gated on `in_state(Trpg)`.
pub struct MapRenderPlugin;

impl Plugin for MapRenderPlugin {
    fn build(&self, app: &mut App) {
        app
            .init_resource::<SceneTransition>()
            .init_resource::<DragState>()
            // Setup: camera, map background, fade overlay, UI — on TRPG mode entry
            .add_systems(OnEnter(ViewerMode::Trpg), (
                map::setup_camera,
                map::setup_map_background,
                overlay::setup_weather_overlay,
                overlay::setup_mood_overlay,
                transition::setup_fade_overlay,
                ui::setup_ui,
            ))
            // Update: character sprites, positions, HP bars, effects, transitions, UI
            .add_systems(Update, (
                characters::spawn_character_sprites,
                characters::update_character_positions,
                characters::update_hp_bars,
                characters::apply_death_visuals,
                characters::handle_drag_start,
                characters::handle_drag,
                characters::handle_drag_end,
                map::update_map_label,
                map::update_map_texture,
                fx::spawn_damage_text,
                fx::animate_floating_text,
                overlay::update_weather_overlay,
                overlay::update_mood_overlay,
                overlay::spawn_prop_notification,
                transition::trigger_scene_transition,
                transition::animate_scene_transition,
                ui::handle_button_interactions,
                ui::manage_menus,
                ui::handle_menu_item_clicks,
            ).run_if(in_state(ViewerMode::Trpg)))
            // Cleanup: despawn all TRPG scene entities and reset resources
            .add_systems(OnExit(ViewerMode::Trpg), cleanup_trpg_scene);
    }
}

/// Despawns all entities owned by the TRPG scene and resets transient resources.
///
/// Each entity type is identified by its marker component — this is why every
/// spawned entity in the TRPG scene must carry at least one marker.
fn cleanup_trpg_scene(
    mut commands: Commands,
    trpg_entities: Query<
        Entity,
        Or<(
            With<GameCamera>,
            With<MapToken>,
            With<MapBackground>,
            With<FadeOverlay>,
            With<FloatingText>,
            With<HpBarSprite>,
            With<WeatherOverlay>,
            With<MoodOverlay>,
            With<UiMarker>,
        )>,
    >,
    mut scene_transition: ResMut<SceneTransition>,
) {
    let count = trpg_entities.iter().count();
    for entity in &trpg_entities {
        // Use try_despawn to avoid panics when parent despawn already
        // recursively removed child entities (e.g., HpBarSprite children
        // of MapToken entities).
        commands.entity(entity).try_despawn();
    }

    // Reset the scene transition resource so re-entering Trpg starts clean
    *scene_transition = SceneTransition::default();

    log::info!("TRPG scene cleanup: despawned {} entities", count);
}
