//! UI widgets and interaction systems for TRPG viewer.

use bevy::prelude::*;

/// Marker component for UI entities spawned by the TRPG viewer.
#[derive(Component)]
pub struct UiMarker;

#[derive(Component)]
pub struct SettingsButton;

#[derive(Component)]
pub struct DevButton;

#[derive(Component)]
pub struct SettingsMenu;

#[derive(Component)]
pub struct DevMenu;

#[derive(Component)]
pub struct CloseMenuButton;

/// Tracks UI state toggles.
#[derive(Resource, Default)]
pub struct UiState {
    pub settings_menu_open: bool,
    pub dev_menu_open: bool,
}

/// Spawns lightweight in-canvas UI controls.
pub fn setup_ui(mut commands: Commands) {
    commands.insert_resource(UiState::default());

    commands
        .spawn((
            Node {
                width: Val::Percent(100.0),
                height: Val::Percent(100.0),
                position_type: PositionType::Absolute,
                ..default()
            },
            UiMarker,
        ))
        .with_children(|parent| {
            parent
                .spawn((
                    Button,
                    SettingsButton,
                    UiMarker,
                    Node {
                        position_type: PositionType::Absolute,
                        right: Val::Px(10.0),
                        top: Val::Px(10.0),
                        width: Val::Px(40.0),
                        height: Val::Px(40.0),
                        justify_content: JustifyContent::Center,
                        align_items: AlignItems::Center,
                        ..default()
                    },
                    BackgroundColor(Color::srgb(0.2, 0.2, 0.3)),
                ))
                .with_children(|parent| {
                    parent.spawn((
                        Text::new("⚙"),
                        TextFont {
                            font_size: 20.0,
                            ..default()
                        },
                        TextColor(Color::srgb(1.0, 1.0, 1.0)),
                    ));
                });

            parent
                .spawn((
                    Button,
                    DevButton,
                    UiMarker,
                    Node {
                        position_type: PositionType::Absolute,
                        left: Val::Px(10.0),
                        bottom: Val::Px(10.0),
                        width: Val::Px(40.0),
                        height: Val::Px(40.0),
                        justify_content: JustifyContent::Center,
                        align_items: AlignItems::Center,
                        ..default()
                    },
                    BackgroundColor(Color::srgb(0.3, 0.2, 0.2)),
                ))
                .with_children(|parent| {
                    parent.spawn((
                        Text::new("🔧"),
                        TextFont {
                            font_size: 20.0,
                            ..default()
                        },
                        TextColor(Color::srgb(1.0, 1.0, 1.0)),
                    ));
                });

            parent.spawn((
                UiMarker,
                Text::new("MASC Viewer v0.1.0"),
                TextFont {
                    font_size: 14.0,
                    ..default()
                },
                TextColor(Color::srgb(0.7, 0.7, 0.7)),
                Node {
                    position_type: PositionType::Absolute,
                    left: Val::Px(10.0),
                    top: Val::Px(10.0),
                    ..default()
                },
            ));
        });
}

/// Handles button click interactions.
pub fn handle_button_interactions(
    mut ui_state: ResMut<UiState>,
    interactions: Query<
        (&Interaction, Option<&SettingsButton>, Option<&DevButton>),
        (Changed<Interaction>, With<Button>),
    >,
) {
    for (interaction, settings_btn, dev_btn) in &interactions {
        if *interaction != Interaction::Pressed {
            continue;
        }
        if settings_btn.is_some() {
            ui_state.settings_menu_open = !ui_state.settings_menu_open;
            log::info!("Settings menu toggled: {}", ui_state.settings_menu_open);
        }
        if dev_btn.is_some() {
            ui_state.dev_menu_open = !ui_state.dev_menu_open;
            log::info!("Dev menu toggled: {}", ui_state.dev_menu_open);
        }
    }
}
