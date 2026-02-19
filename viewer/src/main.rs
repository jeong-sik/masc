mod config;
mod mode;
mod theme;

// Domain modules — compiled unconditionally, but systems are gated on ViewerMode.
mod assets;
mod audio;
mod dom;
mod game;
mod http;
mod render;
mod shaders;
mod sse;

use bevy::prelude::*;
#[cfg(not(target_arch = "wasm32"))]
use bevy::asset::{AssetMetaCheck, AssetPlugin};

use mode::ModePlugin;
use theme::ThemePlugin;
#[cfg(not(target_arch = "wasm32"))]
use theme::ViewerTheme;

#[cfg(target_arch = "wasm32")]
fn main() {
    console_error_panic_hook::set_once();

    App::new()
        // Web fallback path: avoid GPU surface creation so DOM-first viewer can boot.
        .add_plugins(MinimalPlugins)
        .add_plugins(bevy::state::app::StatesPlugin)
        .add_plugins((ModePlugin, ThemePlugin))
        // DOM + session systems only; renderer/audio plugins are skipped on wasm fallback.
        .add_plugins((
            sse::SsePlugin,
            game::GameStatePlugin,
            dom::DomBridgePlugin,
        ))
        .run();
}

#[cfg(not(target_arch = "wasm32"))]
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
        .insert_resource(ClearColor(default_theme.clear_color()))
        .add_plugins((ModePlugin, ThemePlugin))
        .add_plugins((
            sse::SsePlugin,
            game::GameStatePlugin,
            render::MapRenderPlugin,
            shaders::PostProcessPlugin,
            dom::DomBridgePlugin,
            audio::AudioPlugin,
        ))
        .add_systems(Update, shaders::post_process::update_post_process_time)
        .run();
}
