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

/// Actions that can be triggered from menu items.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum MenuAction {
    // Settings menu
    SoundToggle,
    MusicToggle,
    AutoSaveToggle,
    Fullscreen,
    // Dev menu
    ShowFps,
    DebugOverlay,
    ReloadAssets,
    DumpState,
}

/// Marker component for menu items with their associated action.
#[derive(Component)]
pub struct MenuItem(pub MenuAction);

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
            // Settings button (top right)
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

            // Dev button (bottom left)
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

            // Version label (top left)
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

/// Manages menu spawning/despawning based on UiState.
pub fn manage_menus(
    mut commands: Commands,
    ui_state: Res<UiState>,
    settings_menu: Query<Entity, With<SettingsMenu>>,
    dev_menu: Query<Entity, With<DevMenu>>,
) {
    // Settings menu
    let settings_exists = settings_menu.iter().count() > 0;
    if ui_state.settings_menu_open && !settings_exists {
        spawn_settings_menu(&mut commands);
    } else if !ui_state.settings_menu_open && settings_exists {
        for entity in settings_menu.iter() {
            commands.entity(entity).despawn();
        }
    }

    // Dev menu
    let dev_exists = dev_menu.iter().count() > 0;
    if ui_state.dev_menu_open && !dev_exists {
        spawn_dev_menu(&mut commands);
    } else if !ui_state.dev_menu_open && dev_exists {
        for entity in dev_menu.iter() {
            commands.entity(entity).despawn();
        }
    }
}

/// Spawns the settings menu popup.
fn spawn_settings_menu(commands: &mut Commands) {
    commands
        .spawn((
            Node {
                position_type: PositionType::Absolute,
                right: Val::Px(60.0),
                top: Val::Px(10.0),
                width: Val::Px(200.0),
                flex_direction: FlexDirection::Column,
                padding: UiRect::all(Val::Px(10.0)),
                ..default()
            },
            BackgroundColor(Color::srgb(0.15, 0.15, 0.2)),
            UiMarker,
            SettingsMenu,
        ))
        .with_children(|parent| {
            // Title
            parent.spawn((
                Text::new("⚙️ Settings"),
                TextFont {
                    font_size: 16.0,
                    ..default()
                },
                TextColor(Color::srgb(1.0, 1.0, 1.0)),
                Node {
                    margin: UiRect {
                        bottom: Val::Px(5.0),
                        ..default()
                    },
                    ..default()
                },
            ));

            // Menu items (inline to avoid type annotation issues)
            parent.spawn((
                Button,
                MenuItem(MenuAction::SoundToggle),
                Node {
                    width: Val::Percent(100.0),
                    height: Val::Px(25.0),
                    padding: UiRect::horizontal(Val::Px(5.0)),
                    justify_content: JustifyContent::FlexStart,
                    align_items: AlignItems::Center,
                    ..default()
                },
                BackgroundColor(Color::srgb(0.1, 0.1, 0.15)),
                UiMarker,
            ))
            .with_children(|parent| {
                parent.spawn((
                    Text::new("Sound: ON"),
                    TextFont {
                        font_size: 13.0,
                        ..default()
                    },
                    TextColor(Color::srgb(0.8, 0.8, 0.8)),
                ));
            });

            parent.spawn((
                Button,
                MenuItem(MenuAction::MusicToggle),
                Node {
                    width: Val::Percent(100.0),
                    height: Val::Px(25.0),
                    padding: UiRect::horizontal(Val::Px(5.0)),
                    justify_content: JustifyContent::FlexStart,
                    align_items: AlignItems::Center,
                    ..default()
                },
                BackgroundColor(Color::srgb(0.1, 0.1, 0.15)),
                UiMarker,
            ))
            .with_children(|parent| {
                parent.spawn((
                    Text::new("Music: ON"),
                    TextFont {
                        font_size: 13.0,
                        ..default()
                    },
                    TextColor(Color::srgb(0.8, 0.8, 0.8)),
                ));
            });

            parent.spawn((
                Button,
                MenuItem(MenuAction::AutoSaveToggle),
                Node {
                    width: Val::Percent(100.0),
                    height: Val::Px(25.0),
                    padding: UiRect::horizontal(Val::Px(5.0)),
                    justify_content: JustifyContent::FlexStart,
                    align_items: AlignItems::Center,
                    ..default()
                },
                BackgroundColor(Color::srgb(0.1, 0.1, 0.15)),
                UiMarker,
            ))
            .with_children(|parent| {
                parent.spawn((
                    Text::new("Auto-save: ON"),
                    TextFont {
                        font_size: 13.0,
                        ..default()
                    },
                    TextColor(Color::srgb(0.8, 0.8, 0.8)),
                ));
            });

            parent.spawn((
                Button,
                MenuItem(MenuAction::Fullscreen),
                Node {
                    width: Val::Percent(100.0),
                    height: Val::Px(25.0),
                    padding: UiRect::horizontal(Val::Px(5.0)),
                    justify_content: JustifyContent::FlexStart,
                    align_items: AlignItems::Center,
                    ..default()
                },
                BackgroundColor(Color::srgb(0.1, 0.1, 0.15)),
                UiMarker,
            ))
            .with_children(|parent| {
                parent.spawn((
                    Text::new("Fullscreen"),
                    TextFont {
                        font_size: 13.0,
                        ..default()
                    },
                    TextColor(Color::srgb(0.8, 0.8, 0.8)),
                ));
            });
        });
}

/// Spawns the dev menu popup.
fn spawn_dev_menu(commands: &mut Commands) {
    commands
        .spawn((
            Node {
                position_type: PositionType::Absolute,
                left: Val::Px(60.0),
                bottom: Val::Px(10.0),
                width: Val::Px(200.0),
                flex_direction: FlexDirection::Column,
                padding: UiRect::all(Val::Px(10.0)),
                ..default()
            },
            BackgroundColor(Color::srgb(0.2, 0.15, 0.15)),
            UiMarker,
            DevMenu,
        ))
        .with_children(|parent| {
            // Title
            parent.spawn((
                Text::new("🔧 Developer"),
                TextFont {
                    font_size: 16.0,
                    ..default()
                },
                TextColor(Color::srgb(1.0, 1.0, 1.0)),
                Node {
                    margin: UiRect {
                        bottom: Val::Px(5.0),
                        ..default()
                    },
                    ..default()
                },
            ));

            // Dev options
            parent.spawn((
                Button,
                MenuItem(MenuAction::ShowFps),
                Node {
                    width: Val::Percent(100.0),
                    height: Val::Px(25.0),
                    padding: UiRect::horizontal(Val::Px(5.0)),
                    justify_content: JustifyContent::FlexStart,
                    align_items: AlignItems::Center,
                    ..default()
                },
                BackgroundColor(Color::srgb(0.1, 0.1, 0.15)),
                UiMarker,
            ))
            .with_children(|parent| {
                parent.spawn((
                    Text::new("Show FPS"),
                    TextFont {
                        font_size: 13.0,
                        ..default()
                    },
                    TextColor(Color::srgb(0.8, 0.8, 0.8)),
                ));
            });

            parent.spawn((
                Button,
                MenuItem(MenuAction::DebugOverlay),
                Node {
                    width: Val::Percent(100.0),
                    height: Val::Px(25.0),
                    padding: UiRect::horizontal(Val::Px(5.0)),
                    justify_content: JustifyContent::FlexStart,
                    align_items: AlignItems::Center,
                    ..default()
                },
                BackgroundColor(Color::srgb(0.1, 0.1, 0.15)),
                UiMarker,
            ))
            .with_children(|parent| {
                parent.spawn((
                    Text::new("Debug Overlay"),
                    TextFont {
                        font_size: 13.0,
                        ..default()
                    },
                    TextColor(Color::srgb(0.8, 0.8, 0.8)),
                ));
            });

            parent.spawn((
                Button,
                MenuItem(MenuAction::ReloadAssets),
                Node {
                    width: Val::Percent(100.0),
                    height: Val::Px(25.0),
                    padding: UiRect::horizontal(Val::Px(5.0)),
                    justify_content: JustifyContent::FlexStart,
                    align_items: AlignItems::Center,
                    ..default()
                },
                BackgroundColor(Color::srgb(0.1, 0.1, 0.15)),
                UiMarker,
            ))
            .with_children(|parent| {
                parent.spawn((
                    Text::new("Reload Assets"),
                    TextFont {
                        font_size: 13.0,
                        ..default()
                    },
                    TextColor(Color::srgb(0.8, 0.8, 0.8)),
                ));
            });

            parent.spawn((
                Button,
                MenuItem(MenuAction::DumpState),
                Node {
                    width: Val::Percent(100.0),
                    height: Val::Px(25.0),
                    padding: UiRect::horizontal(Val::Px(5.0)),
                    justify_content: JustifyContent::FlexStart,
                    align_items: AlignItems::Center,
                    ..default()
                },
                BackgroundColor(Color::srgb(0.1, 0.1, 0.15)),
                UiMarker,
            ))
            .with_children(|parent| {
                parent.spawn((
                    Text::new("Dump State"),
                    TextFont {
                        font_size: 13.0,
                        ..default()
                    },
                    TextColor(Color::srgb(0.8, 0.8, 0.8)),
                ));
            });
        });
}

/// Handles menu item click interactions.
///
/// Logs the action for now. Future expansion: connect to actual systems
/// (audio toggles, FPS counter, state dump, etc.).
pub fn handle_menu_item_clicks(
    interactions: Query<
        (&Interaction, &MenuItem),
        (Changed<Interaction>, With<Button>),
    >,
) {
    for (interaction, menu_item) in &interactions {
        if *interaction != Interaction::Pressed {
            continue;
        }

        match menu_item.0 {
            MenuAction::SoundToggle => {
                log::info!("Menu action: Sound toggled");
                // TODO: Connect to audio system
            }
            MenuAction::MusicToggle => {
                log::info!("Menu action: Music toggled");
                // TODO: Connect to audio system
            }
            MenuAction::AutoSaveToggle => {
                log::info!("Menu action: Auto-save toggled");
                // TODO: Connect to save system
            }
            MenuAction::Fullscreen => {
                log::info!("Menu action: Toggle fullscreen");
                // TODO: Switch to fullscreen mode
            }
            MenuAction::ShowFps => {
                log::info!("Menu action: Toggle FPS display");
                // TODO: Enable/disable FPS counter
            }
            MenuAction::DebugOverlay => {
                log::info!("Menu action: Toggle debug overlay");
                // TODO: Show/hide debug info
            }
            MenuAction::ReloadAssets => {
                log::info!("Menu action: Reload assets");
                // TODO: Trigger asset hot-reload
            }
            MenuAction::DumpState => {
                log::info!("Menu action: Dump game state");
                // TODO: Serialize and log current state
            }
        }
    }
}

