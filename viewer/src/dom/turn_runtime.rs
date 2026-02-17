use bevy::prelude::*;

use crate::game::components::Actor;
use crate::game::lifecycle::TrpgLifecycleState;
use crate::game::state::{RoomState, TurnProgressState};

/// Tracks last-rendered runtime status snapshot to avoid redundant DOM updates.
#[derive(Resource, Default)]
pub struct TurnRuntimeCache {
    pub last_snapshot: String,
}

#[cfg(target_arch = "wasm32")]
use super::escape::html_escape;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;
#[cfg(target_arch = "wasm32")]
use web_sys::HtmlInputElement;

#[cfg(target_arch = "wasm32")]
fn pretty_phase(phase: &str) -> String {
    let normalized = phase.trim().replace('_', " ");
    if normalized.is_empty() {
        "-".to_string()
    } else {
        normalized
    }
}

#[cfg(target_arch = "wasm32")]
fn room_status_class(state: TrpgLifecycleState) -> &'static str {
    match state {
        TrpgLifecycleState::Running => "status-active",
        TrpgLifecycleState::Stopped => "status-paused",
        TrpgLifecycleState::Ended => "status-ended",
        TrpgLifecycleState::Unavailable => "status-unavailable",
        TrpgLifecycleState::Loading => "status-loading",
        TrpgLifecycleState::Lobby | TrpgLifecycleState::Unknown => "status-idle",
    }
}

#[cfg(target_arch = "wasm32")]
fn room_status_label(state: TrpgLifecycleState) -> &'static str {
    state.label()
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
    let lifecycle = TrpgLifecycleState::from_room_progress(&room_state.status, &progress.room_status);
    let room_status_key = crate::game::lifecycle::normalize_status(&room_status_raw);
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

    let current_status = if !lifecycle.accepts_player_input() {
        lifecycle.label_ko()
    } else if current_actor != "-" {
        "thinking"
    } else {
        "waiting"
    };

    let input_status = if lifecycle.accepts_player_input() {
        "enabled"
    } else {
        "disabled"
    };

    let snapshot = format!(
        "{}|{}|{}|{}|{}|{}|{}|{}|{}",
        room_status_key,
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

        let room_class = room_status_class(lifecycle);
        let party_class = if total_party > 0 && alive_party <= 0 {
            "status-wipe"
        } else {
            "status-active"
        };
        let input_class = if lifecycle.accepts_player_input() {
            "status-active"
        } else {
            room_class
        };

        if let Some(room_status_el) = document.get_element_by_id("room-status") {
            let room_id = crate::config::current_room_id();
            room_status_el.set_text_content(Some(&format!(
                "room {} · {}",
                room_id,
                lifecycle.label_ko()
            )));
            let _ = room_status_el.set_attribute("data-lifecycle", lifecycle.css_class());
            let _ = room_status_el.set_attribute(
                "title",
                &format!(
                    "{} | turn {} | phase {} | raw {}",
                    lifecycle.help_text(),
                    turn,
                    phase,
                    room_status_key
                ),
            );
        }

        let inferred_dm = if !progress.dm_keeper.trim().is_empty() {
            progress.dm_keeper.trim().to_string()
        } else {
            actors
                .iter()
                .find(|actor| actor.id == "dm" && !actor.keeper.trim().is_empty())
                .map(|actor| actor.keeper.trim().to_string())
                .unwrap_or_default()
        };
        if let Some(dm_input) = document
            .get_element_by_id("round-run-dm")
            .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        {
            if dm_input.value().trim().is_empty() && !inferred_dm.is_empty() {
                dm_input.set_value(&inferred_dm);
            }
        }

        let inferred_player_pairs = actors
            .iter()
            .filter(|actor| actor.id != "dm" && !actor.keeper.trim().is_empty())
            .map(|actor| format!("{}={}", actor.id.trim(), actor.keeper.trim()))
            .collect::<Vec<_>>();
        if let Some(players_input) = document
            .get_element_by_id("round-run-players")
            .and_then(|el| el.dyn_into::<HtmlInputElement>().ok())
        {
            if players_input.value().trim().is_empty() && !inferred_player_pairs.is_empty() {
                players_input.set_value(&inferred_player_pairs.join(","));
            }
        }

        if let Some(summary) = document.get_element_by_id("round-run-summary") {
            if summary.text_content().unwrap_or_default().trim().is_empty()
                && !inferred_dm.is_empty()
                && !inferred_player_pairs.is_empty()
            {
                summary.set_text_content(Some(&format!(
                    "DM: {} · Players: {}",
                    inferred_dm,
                    inferred_player_pairs.join(", ")
                )));
                let _ = summary.set_attribute("style", "display:block");
            }
        }

        let html = format!(
            r#"
<div class="turn-runtime-grid">
  <div class="turn-runtime-item turn-runtime-item-wide"><span class="k">Lifecycle</span><span class="v {lifecycle_class}">{lifecycle_label}</span></div>
  <div class="turn-runtime-item turn-runtime-item-wide"><span class="k">Definition</span><span class="v">{lifecycle_help}</span></div>
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
            lifecycle_class = format!("{} {}", room_class, lifecycle.css_class()),
            lifecycle_label = html_escape(&format!("{} ({})", lifecycle.label(), lifecycle.label_ko())),
            lifecycle_help = html_escape(lifecycle.help_text()),
            room_class = room_class,
            room = html_escape(room_status_label(lifecycle)),
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
