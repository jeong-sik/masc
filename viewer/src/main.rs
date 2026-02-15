mod config;
mod mode;
mod theme;

// Domain modules — compiled unconditionally, but systems are gated on ViewerMode.
mod assets;
mod dom;
mod game;
mod render;
mod shaders;
mod sse;

use bevy::asset::{AssetMetaCheck, AssetPlugin};
use bevy::prelude::*;

use mode::ModePlugin;
use theme::{ThemePlugin, ViewerTheme};

fn main() {
    let default_theme = ViewerTheme::default();

    App::new()
        .add_plugins(
            DefaultPlugins
                .set(WindowPlugin {
                    primary_window: Some(Window {
                        title: "MASC Viewer".into(),
                        canvas: Some("#bevy-canvas".into()),
                        prevent_default_event_handling: false,
                        ..default()
                    }),
                    ..default()
                })
                .set(AssetPlugin {
                    meta_check: AssetMetaCheck::Never,
                    ..default()
                }),
        )
        // Initial clear color from default theme (ThemePlugin takes over on changes)
        .insert_resource(ClearColor(default_theme.clear_color()))
        // ── Mode infrastructure (always active) ──
        .add_plugins((ModePlugin, ThemePlugin))
        // ── Domain plugins (systems within are gated on ViewerMode) ──
        .add_plugins((
            sse::SsePlugin,
            game::GameStatePlugin,
            render::MapRenderPlugin,
            shaders::PostProcessPlugin,
            dom::DomBridgePlugin,
        ))
        .add_systems(Update, shaders::post_process::update_post_process_time)
        .run();
}
