pub mod components;
pub mod events;
pub mod http;
pub mod state;
pub mod systems;

use bevy::prelude::*;
use events::*;
use state::*;

use crate::mode::ViewerMode;

/// Plugin that registers game state resources, events, and systems.
///
/// Resources and events are registered unconditionally (type registrations, zero cost).
/// All runtime systems are gated on `ViewerMode::Trpg`.
pub struct GameStatePlugin;

impl Plugin for GameStatePlugin {
    fn build(&self, app: &mut App) {
        app
            // Resources (always registered — inert when not in TRPG mode)
            .init_resource::<RoomState>()
            .init_resource::<MapState>()
            .init_resource::<ConnectionStatus>()
            .init_resource::<OverlayState>()
            .init_resource::<TurnProgressState>()
            .init_resource::<ChoiceState>()
            .init_resource::<CombatState>()
            .init_resource::<http::ActiveTrpgRoom>()
            // Events (type registrations — always available)
            .add_message::<DiceRolled>()
            .add_message::<HpChanged>()
            .add_message::<NarrativeReceived>()
            .add_message::<AreaMoved>()
            .add_message::<TurnAdvanced>()
            .add_message::<ChoiceAvailable>()
            .add_message::<ChoiceResolved>()
            .add_message::<ItemAcquired>()
            .add_message::<CharacterDied>()
            .add_message::<CombatStarted>()
            .add_message::<WeatherChanged>()
            .add_message::<MoodChanged>()
            .add_message::<TurnProgressUpdated>()
            // Phase 1: High-frequency events
            .add_message::<PartySelected>()
            .add_message::<RoomCreated>()
            .add_message::<RoomStarted>()
            .add_message::<SessionStarted>()
            .add_message::<PhaseChanged>()
            .add_message::<TurnStarted>()
            .add_message::<KeeperUnavailable>()
            // Phase 2: Intervention + Actor events
            .add_message::<InterventionSubmitted>()
            .add_message::<InterventionApplied>()
            .add_message::<ActorSpawned>()
            .add_message::<ActorDeleted>()
            .add_message::<ActorClaimed>()
            .add_message::<ActorReleased>()
            .add_message::<ActorUpdated>()
            .add_message::<RoomEnded>()
            .add_message::<TurnActionResolved>()
            .add_message::<SceneTransitioned>()
            // ── TRPG-gated systems ──
            .add_systems(
                OnEnter(ViewerMode::Trpg),
                (systems::reset_turn_progress, http::fetch_initial_state),
            )
            .add_systems(Update, (
                http::refresh_state_on_room_change,
                http::apply_initial_state,
                systems::apply_hp_change,
                systems::apply_area_move,
                systems::apply_turn_advance,
                systems::apply_turn_progress,
                systems::apply_item_acquired,
                systems::apply_character_death,
                systems::apply_weather_change,
                systems::apply_mood_change,
                systems::apply_choice_available,
                systems::apply_choice_resolved,
                systems::apply_combat_started,
            ).run_if(in_state(ViewerMode::Trpg)));
    }
}
