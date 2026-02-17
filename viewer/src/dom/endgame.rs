//! Endgame detection and overlay rendering.
//!
//! Three detection paths:
//! 1. **TPK** — all `Actor` entities have `is_dead = true`
//! 2. **Quest complete** — `NarrativeReceived` with `phase == "endgame"`
//! 3. **Round runner signal** — `RoundRunner.game_ended` atomic flag

use bevy::prelude::*;
use std::sync::atomic::Ordering;

use crate::game::components::Actor;
use crate::game::events::NarrativeReceived;
use crate::game::round_runner::RoundRunner;

/// Tracks whether the endgame overlay has been shown (prevents re-trigger).
#[derive(Resource, Default)]
pub struct EndgameState {
    pub triggered: bool,
}

/// Monitors multiple signals and triggers the endgame overlay once.
pub fn detect_endgame(
    actors: Query<&Actor>,
    runner: Option<Res<RoundRunner>>,
    mut narratives: MessageReader<NarrativeReceived>,
    mut endgame: ResMut<EndgameState>,
) {
    if endgame.triggered {
        // Drain the reader even when already triggered to avoid stale buffers.
        for _ in narratives.read() {}
        return;
    }

    // Path 1: TPK — all actors dead.
    let actor_count = actors.iter().count();
    if actor_count > 0 {
        let dead_count = actors.iter().filter(|a| a.is_dead).count();
        if dead_count == actor_count {
            endgame.triggered = true;
            show_endgame_overlay("파티가 전멸했습니다.", false);
            if let Some(runner) = &runner {
                runner.game_ended.store(true, Ordering::SeqCst);
            }
            // Drain remaining narratives.
            for _ in narratives.read() {}
            return;
        }
    }

    // Path 2: Quest complete — endgame narrative phase.
    for NarrativeReceived(payload) in narratives.read() {
        if payload.phase == "endgame" {
            endgame.triggered = true;
            show_endgame_overlay(&payload.text, true);
            return;
        }
    }

    // Path 3: Round runner detected game ended via response JSON.
    if let Some(runner) = &runner {
        if runner.game_ended.load(Ordering::SeqCst) {
            endgame.triggered = true;
            show_endgame_overlay("모험이 끝났습니다.", true);
        }
    }
}

/// Render a full-screen endgame overlay via DOM.
fn show_endgame_overlay(message: &str, is_victory: bool) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let Some(body) = doc.body() else { return };

        let overlay = match doc.create_element("div") {
            Ok(el) => el,
            Err(_) => return,
        };

        let class = if is_victory {
            "endgame-overlay victory"
        } else {
            "endgame-overlay defeat"
        };
        overlay.set_class_name(class);

        let title = if is_victory { "임무 완료" } else { "전멸" };

        // Build inner HTML with safe text insertion for the message.
        // Title is a fixed Korean string (safe). Message uses set_text_content below.
        let html = format!(
            "<div class=\"endgame-content\">\
                <h1 class=\"endgame-title\">{title}</h1>\
                <p class=\"endgame-message\"></p>\
                <button class=\"endgame-btn\" \
                    onclick=\"this.closest('.endgame-overlay').remove()\">닫기</button>\
            </div>"
        );
        overlay.set_inner_html(&html);

        // Set message text safely (auto-escapes HTML entities).
        if let Ok(msg_el) = overlay.query_selector(".endgame-message") {
            if let Some(el) = msg_el {
                el.set_text_content(Some(message));
            }
        }

        body.append_child(&overlay).ok();
    }

    // Suppress unused warnings on native builds.
    let _ = (message, is_victory);
}
