//! UI widgets and interaction systems for TRPG viewer.

use bevy::ecs::relationship::Relationship;
use bevy::ecs::system::SystemParam;
use bevy::prelude::*;
use bevy::window::{MonitorSelection, PrimaryWindow, WindowMode};

use crate::audio::AudioSettings;
use crate::game::state::{WorkspaceState, TurnProgressState};

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
    pub auto_save_enabled: bool,
    pub show_fps: bool,
    pub debug_overlay: bool,
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
                        Text::new("S"),
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
                        Text::new("D"),
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
#[allow(clippy::type_complexity)]
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
            Resizable::default(),
        ))
        .with_children(|parent| {
            // Title
            parent.spawn((
                Text::new("Settings"),
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
            parent
                .spawn((
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

            parent
                .spawn((
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

            parent
                .spawn((
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

            parent
                .spawn((
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
            Resizable::default(),
        ))
        .with_children(|parent| {
            // Title
            parent.spawn((
                Text::new("Developer"),
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
            parent
                .spawn((
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

            parent
                .spawn((
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

            parent
                .spawn((
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

            parent
                .spawn((
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
#[allow(clippy::type_complexity)]
pub fn handle_menu_item_clicks(
    interactions: Query<(Entity, &Interaction, &MenuItem), (Changed<Interaction>, With<Button>)>,
    children_query: Query<&Children>,
    mut text_query: Query<&mut Text>,
    mut audio: ResMut<AudioSettings>,
    mut runtime: MenuActionRuntime,
) {
    for (entity, interaction, menu_item) in &interactions {
        if *interaction != Interaction::Pressed {
            continue;
        }

        match menu_item.0 {
            MenuAction::SoundToggle => {
                audio.sound_enabled = !audio.sound_enabled;
                let label = if audio.sound_enabled {
                    "Sound: ON"
                } else {
                    "Sound: OFF"
                };
                update_button_text(entity, label, &children_query, &mut text_query);
                log::info!("Sound toggled: {}", audio.sound_enabled);
            }
            MenuAction::MusicToggle => {
                audio.music_enabled = !audio.music_enabled;
                let label = if audio.music_enabled {
                    "Music: ON"
                } else {
                    "Music: OFF"
                };
                update_button_text(entity, label, &children_query, &mut text_query);
                log::info!("Music toggled: {}", audio.music_enabled);
            }
            MenuAction::AutoSaveToggle => {
                runtime.ui_state.auto_save_enabled = !runtime.ui_state.auto_save_enabled;
                let label = if runtime.ui_state.auto_save_enabled {
                    "Auto-save: ON"
                } else {
                    "Auto-save: OFF"
                };
                update_button_text(entity, label, &children_query, &mut text_query);
                log::info!("Auto-save toggled: {}", runtime.ui_state.auto_save_enabled);
            }
            MenuAction::Fullscreen => {
                if let Ok(mut window) = runtime.primary_window.single_mut() {
                    let fullscreen = matches!(window.mode, WindowMode::Windowed);
                    window.mode = if fullscreen {
                        WindowMode::BorderlessFullscreen(MonitorSelection::Primary)
                    } else {
                        WindowMode::Windowed
                    };
                    let label = if fullscreen {
                        "Fullscreen: ON"
                    } else {
                        "Fullscreen: OFF"
                    };
                    update_button_text(entity, label, &children_query, &mut text_query);
                    log::info!("Fullscreen toggled: {}", fullscreen);
                }
            }
            MenuAction::ShowFps => {
                runtime.ui_state.show_fps = !runtime.ui_state.show_fps;
                let label = if runtime.ui_state.show_fps {
                    "FPS: ON"
                } else {
                    "FPS: OFF"
                };
                update_button_text(entity, label, &children_query, &mut text_query);
                log::info!("FPS display toggled: {}", runtime.ui_state.show_fps);
            }
            MenuAction::DebugOverlay => {
                runtime.ui_state.debug_overlay = !runtime.ui_state.debug_overlay;
                let label = if runtime.ui_state.debug_overlay {
                    "Debug: ON"
                } else {
                    "Debug: OFF"
                };
                update_button_text(entity, label, &children_query, &mut text_query);
                log::info!("Debug overlay toggled: {}", runtime.ui_state.debug_overlay);
            }
            MenuAction::ReloadAssets => {
                let _ = runtime.asset_server.load_untyped("maps/area_a.jpg");
                let _ = runtime.asset_server.load_untyped("portraits/grimja.png");
                log::info!("Asset reload hint requested (maps/area_a.jpg, portraits/grimja.png)");
            }
            MenuAction::DumpState => {
                log::info!(
                    "State dump | workspace={} status={} turn={} phase={} current_actor={} next_actor={} auto_save={} fps={} debug={}",
                    runtime.workspace_state.id,
                    runtime.workspace_state.status,
                    runtime.workspace_state.turn,
                    runtime.progress.phase,
                    runtime.progress.current_actor,
                    runtime.progress.next_actor,
                    runtime.ui_state.auto_save_enabled,
                    runtime.ui_state.show_fps,
                    runtime.ui_state.debug_overlay
                );
            }
        }
    }
}

/// Walk the entity's children to find the first `Text` component and overwrite it.
fn update_button_text(
    button: Entity,
    label: &str,
    children_query: &Query<&Children>,
    text_query: &mut Query<&mut Text>,
) {
    if let Ok(children) = children_query.get(button) {
        for child in children.iter() {
            if let Ok(mut text) = text_query.get_mut(child) {
                *text = Text::new(label);
                return;
            }
        }
    }
}

#[derive(SystemParam)]
pub struct MenuActionRuntime<'w, 's> {
    pub ui_state: ResMut<'w, UiState>,
    pub primary_window: Query<'w, 's, &'static mut Window, With<PrimaryWindow>>,
    pub asset_server: Res<'w, AssetServer>,
    pub workspace_state: Res<'w, WorkspaceState>,
    pub progress: Res<'w, TurnProgressState>,
}

// ============================================================================
// Widget Resize Handles (Phase 3)
// ============================================================================

/// Which edge or corner of a widget.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ResizeEdge {
    North,
    South,
    East,
    West,
    NorthWest,
    NorthEast,
    SouthWest,
    SouthEast,
}

/// Marker component for resize handle entities.
#[derive(Component)]
pub struct ResizeHandle {
    pub edge: ResizeEdge,
}

/// Marks a widget as resizable with size constraints.
#[derive(Component)]
pub struct Resizable {
    pub min_width: f32,
    pub min_height: f32,
    pub max_width: Option<f32>,
    pub max_height: Option<f32>,
}

impl Default for Resizable {
    fn default() -> Self {
        Self {
            min_width: 100.0,
            min_height: 50.0,
            max_width: None,
            max_height: None,
        }
    }
}

/// Tracks active resize operation.
#[derive(Resource, Default)]
pub struct ResizeState {
    pub resizing_entity: Option<Entity>,
    pub resize_edge: Option<ResizeEdge>,
    pub start_cursor: Vec2,
    pub start_size: Vec2,
}

const HANDLE_SIZE: f32 = 8.0;
const HANDLE_COLOR: Color = Color::srgb(0.3, 0.3, 0.4);

/// Spawns resize handles on resizable widgets.
#[allow(clippy::type_complexity)]
pub fn spawn_resize_handles(
    mut commands: Commands,
    resizable_widgets: Query<(Entity, &Node, &Resizable), (Added<Resizable>, With<UiMarker>)>,
) {
    for (entity, _node, _resizable) in &resizable_widgets {
        // Use default size since calculated_size isn't available in Bevy 0.18
        let size = Vec2::new(200.0, 200.0);
        if size.x <= 0.0 || size.y <= 0.0 {
            continue;
        }

        // Spawn 8 handles (corners + edges)
        let edges = [
            (ResizeEdge::NorthWest, Val::Px(0.0), Val::Px(0.0)),
            (
                ResizeEdge::North,
                Val::Px(size.x / 2.0 - HANDLE_SIZE / 2.0),
                Val::Px(0.0),
            ),
            (
                ResizeEdge::NorthEast,
                Val::Px(size.x - HANDLE_SIZE),
                Val::Px(0.0),
            ),
            (
                ResizeEdge::West,
                Val::Px(0.0),
                Val::Px(size.y / 2.0 - HANDLE_SIZE / 2.0),
            ),
            (
                ResizeEdge::East,
                Val::Px(size.x - HANDLE_SIZE),
                Val::Px(size.y / 2.0 - HANDLE_SIZE / 2.0),
            ),
            (
                ResizeEdge::SouthWest,
                Val::Px(0.0),
                Val::Px(size.y - HANDLE_SIZE),
            ),
            (
                ResizeEdge::South,
                Val::Px(size.x / 2.0 - HANDLE_SIZE / 2.0),
                Val::Px(size.y - HANDLE_SIZE),
            ),
            (
                ResizeEdge::SouthEast,
                Val::Px(size.x - HANDLE_SIZE),
                Val::Px(size.y - HANDLE_SIZE),
            ),
        ];

        for (edge, left, top) in edges {
            let handle = commands
                .spawn((
                    Button,
                    ResizeHandle { edge },
                    Node {
                        position_type: PositionType::Absolute,
                        left,
                        top,
                        width: Val::Px(HANDLE_SIZE),
                        height: Val::Px(HANDLE_SIZE),
                        ..default()
                    },
                    BackgroundColor(HANDLE_COLOR),
                    UiMarker,
                ))
                .id();
            commands.entity(entity).add_child(handle);
        }
    }
}

/// Handles resize start - captures initial state.
#[allow(clippy::type_complexity)]
pub fn handle_resize_start(
    mut resize_state: ResMut<ResizeState>,
    windows: Query<&Window>,
    resize_handles: Query<
        (Entity, &ResizeHandle, &ChildOf, &Interaction),
        (With<Button>, Changed<Interaction>),
    >,
    nodes: Query<&Node>,
) {
    let Ok(window) = windows.single() else {
        return;
    };
    let Some(cursor_pos) = window.cursor_position() else {
        return;
    };

    for (_handle_entity, handle, parent, interaction) in &resize_handles {
        if *interaction == Interaction::Pressed {
            // Access the parent entity from ChildOf component
            let parent_entity = parent.get();
            let Ok(_node) = nodes.get(parent_entity) else {
                continue;
            };

            // Use the Node's size directly (width/height as Val)
            // For resize, we'll use a default starting size since calculated_size isn't available
            let size = Vec2::new(200.0, 200.0); // Default starting size

            resize_state.resizing_entity = Some(parent_entity);
            resize_state.resize_edge = Some(handle.edge);
            resize_state.start_cursor = cursor_pos;
            resize_state.start_size = size;
            log::info!("Resize started: edge={:?}", handle.edge);
            break;
        }
    }
}

/// Handles resize movement - updates widget size.
pub fn handle_resize(
    mut resize_state: ResMut<ResizeState>,
    windows: Query<&Window>,
    mouse_buttons: Res<ButtonInput<MouseButton>>,
    mut nodes: Query<(&Resizable, &mut Node)>,
) {
    let Some(entity) = resize_state.resizing_entity else {
        return;
    };

    // Cancel if mouse released
    if !mouse_buttons.pressed(MouseButton::Left) {
        return;
    }

    let Ok(window) = windows.single() else {
        return;
    };
    let Some(cursor_pos) = window.cursor_position() else {
        return;
    };

    let Ok((resizable, mut node)) = nodes.get_mut(entity) else {
        resize_state.resizing_entity = None;
        return;
    };

    let delta = cursor_pos - resize_state.start_cursor;
    let mut new_size = resize_state.start_size;

    match resize_state.resize_edge {
        Some(ResizeEdge::North) => {
            new_size.y -= delta.y;
            new_size.y = new_size.y.max(resizable.min_height);
        }
        Some(ResizeEdge::South) => {
            new_size.y += delta.y;
            new_size.y = new_size.y.max(resizable.min_height);
        }
        Some(ResizeEdge::East) => {
            new_size.x += delta.x;
            new_size.x = new_size.x.max(resizable.min_width);
        }
        Some(ResizeEdge::West) => {
            new_size.x -= delta.x;
            new_size.x = new_size.x.max(resizable.min_width);
        }
        Some(ResizeEdge::NorthEast) => {
            new_size.y -= delta.y;
            new_size.x += delta.x;
            new_size = new_size.max(Vec2::new(resizable.min_width, resizable.min_height));
        }
        Some(ResizeEdge::NorthWest) => {
            new_size.y -= delta.y;
            new_size.x -= delta.x;
            new_size = new_size.max(Vec2::new(resizable.min_width, resizable.min_height));
        }
        Some(ResizeEdge::SouthEast) => {
            new_size.y += delta.y;
            new_size.x += delta.x;
            new_size = new_size.max(Vec2::new(resizable.min_width, resizable.min_height));
        }
        Some(ResizeEdge::SouthWest) => {
            new_size.y += delta.y;
            new_size.x -= delta.x;
            new_size = new_size.max(Vec2::new(resizable.min_width, resizable.min_height));
        }
        None => {}
    }

    // Apply max constraints
    if let Some(max_w) = resizable.max_width {
        new_size.x = new_size.x.min(max_w);
    }
    if let Some(max_h) = resizable.max_height {
        new_size.y = new_size.y.min(max_h);
    }

    node.width = Val::Px(new_size.x);
    node.height = Val::Px(new_size.y);
}

/// Handles resize end - cleans up state.
pub fn handle_resize_end(
    mut resize_state: ResMut<ResizeState>,
    mouse_buttons: Res<ButtonInput<MouseButton>>,
) {
    if mouse_buttons.just_released(MouseButton::Left) && resize_state.resizing_entity.is_some() {
        log::info!("Resize ended");
        resize_state.resizing_entity = None;
        resize_state.resize_edge = None;
    }
}

/// Updates handle cursor to indicate resize direction.
pub fn update_resize_cursors(
    _windows: Query<&Window>,
    _resize_handles: Query<(&ResizeHandle, &Interaction), With<ResizeHandle>>,
) {
    // Cursor update not directly available in Bevy 0.18 Window API
    // The OS will handle cursor changes automatically
}
