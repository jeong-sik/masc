use bevy::prelude::*;

use crate::game::components::Actor;
use crate::game::state::{RoomState, TurnProgressState};

/// Tracks last-rendered runtime status snapshot to avoid redundant DOM updates.
#[derive(Resource, Default)]
pub struct TurnRuntimeCache {
    pub last_snapshot: String,
}

#[cfg(target_arch = "wasm32")]
use super::escape::html_escape;

#[cfg(target_arch = "wasm32")]
fn pretty_phase(phase: &str) -> String {
    let normalized = phase.trim().replace('_', " ");
    if normalized.is_empty() {
        "-".to_string()
    } else {
        normalized
    }
}

fn normalize_room_status(raw: &str) -> String {
    let normalized = raw.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        "unknown".to_string()
    } else {
        normalized
    }
}

#[cfg(target_arch = "wasm32")]
fn room_status_class(status: &str) -> &'static str {
    match status {
        "active" | "running" | "in_progress" | "round" | "combat" | "briefing" => {
            "status-active"
        }
        "dm_narration" | "party_discussion" | "action_declaration" | "dice_resolution"
        | "outcome_narration" | "state_update" | "transition" => "status-active",
        "paused" => "status-paused",
        "ended" => "status-ended",
        "unavailable" => "status-unavailable",
        "loading" => "status-loading",
        _ => "status-idle",
    }
}

#[cfg(target_arch = "wasm32")]
fn room_status_label(status: &str) -> &'static str {
    match status {
        "active" | "running" | "in_progress" | "round" | "combat" | "briefing" => "RUNNING",
        "dm_narration" | "party_discussion" | "action_declaration" | "dice_resolution"
        | "outcome_narration" | "state_update" | "transition" => "RUNNING",
        "paused" => "PAUSED",
        "ended" => "ENDED",
        "idle" => "IDLE",
        "loading" => "LOADING",
        "unavailable" => "UNAVAILABLE",
        _ => "UNKNOWN",
    }
}

fn room_accepts_input(status: &str) -> bool {
    matches!(
        status,
        "active"
            | "running"
            | "in_progress"
            | "round"
            | "combat"
            | "briefing"
            | "dm_narration"
            | "party_discussion"
            | "action_declaration"
            | "dice_resolution"
            | "outcome_narration"
            | "state_update"
            | "transition"
    )
}

/// Render live TRPG runtime progress:
/// room/turn/phase, current thinker, next actor, last outcome, and party survival.
pub fn update_turn_runtime_dom(
    room_state: Res<RoomState>,
    progress: Res<TurnProgressState>,
    actors: Query<&Actor>,
    mut cache: ResMut<TurnRuntimeCache>,
) {
    let room_status_raw = if !progress.room_status.trim().is_empty() {
        progress.room_status.trim().to_string()
    } else if !room_state.status.trim().is_empty() {
        room_state.status.trim().to_string()
    } else {
        "unknown".to_string()
    };
    let room_status = normalize_room_status(&room_status_raw);
    let turn = if progress.turn > 0 {
        progress.turn
    } else if room_state.turn > 0 {
        room_state.turn
    } else {
        1
    };
    let phase = if !progress.phase.trim().is_empty() {
        progress.phase.trim().to_string()
    } else {
        room_state.phase.as_str().to_string()
    };

    let current_actor = if !progress.current_actor.trim().is_empty() {
        progress.current_actor.trim().to_string()
    } else {
        "-".to_string()
    };
    let next_actor = if !progress.next_actor.trim().is_empty() {
        progress.next_actor.trim().to_string()
    } else {
        "-".to_string()
    };
    let last_result = if !progress.last_actor.trim().is_empty() {
        format!(
            "{} ({})",
            progress.last_actor.trim(),
            if progress.last_result.trim().is_empty() {
                "ok"
            } else {
                progress.last_result.trim()
            }
        )
    } else {
        "-".to_string()
    };

    let (alive_party, total_party) = actors.iter().filter(|actor| actor.id != "dm").fold(
        (0_i32, 0_i32),
        |(alive, total), actor| {
            (
                alive + if !actor.is_dead && actor.hp > 0 { 1 } else { 0 },
                total + 1,
            )
        },
    );
    let party_status = if total_party <= 0 {
        "-".to_string()
    } else if alive_party <= 0 {
        "WIPE".to_string()
    } else {
        format!("{}/{} alive", alive_party, total_party)
    };

    let current_status = if !room_accepts_input(&room_status) {
        room_status.as_str()
    } else if current_actor != "-" {
        "thinking"
    } else {
        "waiting"
    };

    let input_status = if room_accepts_input(&room_status) {
        "enabled"
    } else {
        "disabled"
    };

    let snapshot = format!(
        "{}|{}|{}|{}|{}|{}|{}|{}|{}",
        room_status,
        turn,
        phase,
        current_actor,
        next_actor,
        last_result,
        party_status,
        current_status,
        input_status
    );
    if cache.last_snapshot == snapshot {
        return;
    }
    cache.last_snapshot = snapshot;

    #[cfg(target_arch = "wasm32")]
    {
        let Some(document) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let Some(el) = document.get_element_by_id("turn-runtime") else {
            return;
        };

        let room_class = room_status_class(&room_status);
        let party_class = if total_party > 0 && alive_party <= 0 {
            "status-wipe"
        } else {
            "status-active"
        };
        let input_class = if room_accepts_input(&room_status) {
            "status-active"
        } else {
            room_class
        };

        let html = format!(
            r#"
<div class="turn-runtime-grid">
  <div class="turn-runtime-item"><span class="k">State</span><span class="v {room_class}">{room}</span></div>
  <div class="turn-runtime-item"><span class="k">Turn</span><span class="v">{turn}</span></div>
  <div class="turn-runtime-item"><span class="k">Phase</span><span class="v">{phase}</span></div>
  <div class="turn-runtime-item"><span class="k">Input</span><span class="v {input_class}">{input}</span></div>
  <div class="turn-runtime-item"><span class="k">Now</span><span class="v">{current} · {current_status}</span></div>
  <div class="turn-runtime-item"><span class="k">Next</span><span class="v">{next}</span></div>
  <div class="turn-runtime-item"><span class="k">Last</span><span class="v">{last}</span></div>
  <div class="turn-runtime-item"><span class="k">Party</span><span class="v {party_class}">{party}</span></div>
</div>
"#,
            room_class = room_class,
            room = html_escape(room_status_label(&room_status)),
            turn = turn,
            phase = html_escape(&pretty_phase(&phase)),
            input_class = input_class,
            input = html_escape(input_status),
            current = html_escape(&current_actor),
            current_status = html_escape(current_status),
            next = html_escape(&next_actor),
            last = html_escape(&last_result),
            party_class = party_class,
            party = html_escape(&party_status),
        );
        el.set_inner_html(&html);
    }
}
