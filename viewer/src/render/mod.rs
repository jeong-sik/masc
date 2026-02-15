pub mod characters;
pub mod fx;
pub mod map;
pub mod transition;

use bevy::prelude::*;

use crate::mode::ViewerMode;
use crate::render::transition::SceneTransition;

/// Plugin for 2D scene rendering: map backgrounds, character tokens, HP bars, effects.
///
/// Setup systems run on `OnEnter(Trpg)` — camera, map, and overlays are created
/// when entering TRPG mode. Update systems are gated on `in_state(Trpg)`.
pub struct MapRenderPlugin;

impl Plugin for MapRenderPlugin {
    fn build(&self, app: &mut App) {
        app
            .init_resource::<SceneTransition>()
            // Setup: camera, map background, fade overlay — on TRPG mode entry
            .add_systems(OnEnter(ViewerMode::Trpg), (
                map::setup_camera,
                map::setup_map_background,
                transition::setup_fade_overlay,
            ))
            // Update: character sprites, positions, HP bars, effects, transitions
            .add_systems(Update, (
                characters::spawn_character_sprites,
                characters::update_character_positions,
                characters::update_hp_bars,
                characters::apply_death_visuals,
                map::update_map_label,
                fx::spawn_damage_text,
                fx::animate_floating_text,
                transition::trigger_scene_transition,
                transition::animate_scene_transition,
            ).run_if(in_state(ViewerMode::Trpg)));
        // TODO: OnExit(Trpg) — despawn camera, map entities, character sprites
    }
}
