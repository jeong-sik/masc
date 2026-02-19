//! Audio system for TRPG viewer (WASM-native via web-sys HtmlAudioElement).
//!
//! BGM: looping background music per mood/scene.
//! SFX: one-shot sound effects for game events (dice, combat, transitions).

use bevy::prelude::*;
use web_sys::HtmlAudioElement;

use crate::game::events::*;

// ─── Plugin ─────────────────────────────────

pub struct AudioPlugin;

impl Plugin for AudioPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<AudioSettings>()
            .init_resource::<AudioState>()
            .add_systems(
                Update,
                (
                    sync_bgm_on_mood_change,
                    play_sfx_on_dice_roll,
                    play_sfx_on_turn_advance,
                    play_sfx_on_combat_start,
                    play_sfx_on_death,
                    update_bgm_volume,
                ),
            );
    }
}

// ─── Resources ──────────────────────────────

#[derive(Resource, Debug)]
pub struct AudioSettings {
    pub sound_enabled: bool,
    pub music_enabled: bool,
    pub sound_volume: f64,
    pub music_volume: f64,
}

impl Default for AudioSettings {
    fn default() -> Self {
        Self {
            sound_enabled: true,
            music_enabled: true,
            sound_volume: 0.7,
            music_volume: 0.4,
        }
    }
}

/// Wrapper to make HtmlAudioElement Send+Sync for Bevy resources.
/// Safe in WASM: single-threaded environment, no real concurrency.
struct SendAudioElement(HtmlAudioElement);

// SAFETY: WASM is single-threaded; JsValue pointers are never shared across threads.
unsafe impl Send for SendAudioElement {}
unsafe impl Sync for SendAudioElement {}

impl std::fmt::Debug for SendAudioElement {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SendAudioElement(..)")
    }
}

#[derive(Resource, Default, Debug)]
pub struct AudioState {
    bgm_element: Option<SendAudioElement>,
    current_bgm_track: String,
}

// ─── Asset paths ────────────────────────────

pub mod paths {
    // BGM tracks — ambient loops per mood/scene
    pub const BGM_QUIET_UNEASE: &str = "audio/bgm_quiet_unease.ogg";
    pub const BGM_TENSION_RISING: &str = "audio/bgm_tension_rising.ogg";
    pub const BGM_AMBIGUOUS_CALM: &str = "audio/bgm_ambiguous_calm.ogg";
    pub const BGM_COMBAT: &str = "audio/bgm_combat.ogg";
    pub const BGM_DEFAULT: &str = "audio/bgm_default.ogg";

    // SFX — one-shot effects
    pub const SFX_DICE_ROLL: &str = "audio/sfx_dice_roll.ogg";
    pub const SFX_DICE_SUCCESS: &str = "audio/sfx_dice_success.ogg";
    pub const SFX_DICE_FAIL: &str = "audio/sfx_dice_fail.ogg";
    pub const SFX_TURN_ADVANCE: &str = "audio/sfx_turn_advance.ogg";
    pub const SFX_COMBAT_START: &str = "audio/sfx_combat_start.ogg";
    pub const SFX_DEATH: &str = "audio/sfx_death.ogg";
}

/// Map mood string to BGM path.
fn bgm_for_mood(mood: &str) -> &'static str {
    match mood {
        "quiet_unease" => paths::BGM_QUIET_UNEASE,
        "tension_rising" => paths::BGM_TENSION_RISING,
        "ambiguous_calm" => paths::BGM_AMBIGUOUS_CALM,
        "combat" => paths::BGM_COMBAT,
        _ => paths::BGM_DEFAULT,
    }
}

// ─── Web Audio helpers ──────────────────────

fn create_audio_element(src: &str, looping: bool, volume: f64) -> Option<HtmlAudioElement> {
    let el = HtmlAudioElement::new_with_src(src).ok()?;
    el.set_loop(looping);
    el.set_volume(volume);
    Some(el)
}

fn play_element(el: &HtmlAudioElement) {
    // Browser autoplay policy: play() returns a Promise that may reject.
    // We fire-and-forget; the user's first click on the menu satisfies the
    // gesture requirement for subsequent plays.
    let _ = el.play().ok();
}

fn play_one_shot(src: &str, volume: f64) {
    if let Some(el) = create_audio_element(src, false, volume) {
        play_element(&el);
        // Element is GC'd by the browser after playback ends.
        // To prevent early collection, leak a reference that the browser holds
        // via the playing state. No explicit cleanup needed for short SFX.
        std::mem::forget(el);
    }
}

// ─── Systems ────────────────────────────────

/// Switch BGM when the mood changes.
fn sync_bgm_on_mood_change(
    mut events: MessageReader<MoodChanged>,
    settings: Res<AudioSettings>,
    mut state: ResMut<AudioState>,
) {
    for ev in events.read() {
        let track = bgm_for_mood(&ev.0.mood);
        if track == state.current_bgm_track {
            continue;
        }

        // Stop previous BGM
        if let Some(ref el) = state.bgm_element {
            el.0.pause().ok();
        }

        if settings.music_enabled {
            if let Some(el) = create_audio_element(track, true, settings.music_volume) {
                play_element(&el);
                state.bgm_element = Some(SendAudioElement(el));
            }
        } else {
            state.bgm_element = None;
        }
        state.current_bgm_track = track.to_string();
    }
}

/// Adjust BGM volume when settings change (called every frame, early-outs fast).
fn update_bgm_volume(settings: Res<AudioSettings>, state: Res<AudioState>) {
    if !settings.is_changed() {
        return;
    }

    if let Some(ref el) = state.bgm_element {
        if settings.music_enabled {
            el.0.set_volume(settings.music_volume);
            let _ = el.0.play().ok();
        } else {
            el.0.pause().ok();
        }
    }
}

/// Play dice SFX on roll events.
fn play_sfx_on_dice_roll(mut events: MessageReader<DiceRolled>, settings: Res<AudioSettings>) {
    for ev in events.read() {
        if !settings.sound_enabled {
            continue;
        }
        play_one_shot(paths::SFX_DICE_ROLL, settings.sound_volume);

        let result_sfx = if ev.0.result == "success" || ev.0.result == "critical_success" {
            paths::SFX_DICE_SUCCESS
        } else {
            paths::SFX_DICE_FAIL
        };
        play_one_shot(result_sfx, settings.sound_volume);
    }
}

/// Play turn advance chime.
fn play_sfx_on_turn_advance(mut events: MessageReader<TurnAdvanced>, settings: Res<AudioSettings>) {
    for _ev in events.read() {
        if settings.sound_enabled {
            play_one_shot(paths::SFX_TURN_ADVANCE, settings.sound_volume);
        }
    }
}

/// Play combat start sting.
fn play_sfx_on_combat_start(
    mut events: MessageReader<CombatStarted>,
    settings: Res<AudioSettings>,
) {
    for _ev in events.read() {
        if settings.sound_enabled {
            play_one_shot(paths::SFX_COMBAT_START, settings.sound_volume);
        }
    }
}

/// Play death SFX.
fn play_sfx_on_death(mut events: MessageReader<CharacterDied>, settings: Res<AudioSettings>) {
    for _ev in events.read() {
        if settings.sound_enabled {
            play_one_shot(paths::SFX_DEATH, settings.sound_volume);
        }
    }
}
