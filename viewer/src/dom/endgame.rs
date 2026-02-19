//! Endgame detection and overlay rendering.
//!
//! Three detection paths:
//! 1. **TPK** — all `Actor` entities have `is_dead = true`
//! 2. **Quest complete** — `NarrativeReceived` with `phase == "endgame"`
//! 3. **Round runner signal** — `RoundRunner.game_ended` atomic flag

use bevy::prelude::*;
use std::sync::atomic::Ordering;

use crate::game::components::Actor;
use crate::game::events::{NarrativeReceived, SessionOutcome};
use crate::game::round_runner::RoundRunner;

/// Tracks whether the endgame overlay has been shown (prevents re-trigger).
#[derive(Resource, Default)]
pub struct EndgameState {
    pub triggered: bool,
}

#[derive(Copy, Clone)]
enum EndgameTone {
    Victory,
    Defeat,
    Draw,
}

/// Monitors multiple signals and triggers the endgame overlay once.
pub fn detect_endgame(
    actors: Query<&Actor>,
    runner: Option<Res<RoundRunner>>,
    mut narratives: MessageReader<NarrativeReceived>,
    mut outcomes: MessageReader<SessionOutcome>,
    mut endgame: ResMut<EndgameState>,
) {
    if endgame.triggered {
        // Drain the reader even when already triggered to avoid stale buffers.
        for _ in narratives.read() {}
        for _ in outcomes.read() {}
        return;
    }

    // Path 0: Canonical session outcome.
    for SessionOutcome(payload) in outcomes.read() {
        endgame.triggered = true;
        let tone = match payload.outcome.as_str() {
            "victory" => EndgameTone::Victory,
            "defeat" => EndgameTone::Defeat,
            _ => EndgameTone::Draw,
        };
        let message = if payload.summary.trim().is_empty() {
            "모험이 마무리되었습니다."
        } else {
            payload.summary.as_str()
        };
        show_endgame_overlay(message, tone);
        if let Some(runner) = &runner {
            runner.game_ended.store(true, Ordering::SeqCst);
        }
        for _ in narratives.read() {}
        return;
    }

    // Path 1: TPK — all actors dead.
    let actor_count = actors.iter().count();
    if actor_count > 0 {
        let dead_count = actors.iter().filter(|a| a.is_dead).count();
        if dead_count == actor_count {
            endgame.triggered = true;
            show_endgame_overlay("파티가 전멸했습니다.", EndgameTone::Defeat);
            if let Some(runner) = &runner {
                runner.game_ended.store(true, Ordering::SeqCst);
            }
            // Drain remaining narratives.
            for _ in narratives.read() {}
            for _ in outcomes.read() {}
            return;
        }
    }

    // Path 2: Quest complete — endgame narrative phase.
    for NarrativeReceived(payload) in narratives.read() {
        if payload.phase == "endgame" {
            endgame.triggered = true;
            show_endgame_overlay(&payload.text, EndgameTone::Victory);
            return;
        }
    }

    // Path 3: Round runner detected game ended via response JSON.
    if let Some(runner) = &runner {
        if runner.game_ended.load(Ordering::SeqCst) {
            endgame.triggered = true;
            show_endgame_overlay("모험이 끝났습니다.", EndgameTone::Victory);
        }
    }
}

/// Render a full-screen endgame overlay via DOM.
fn show_endgame_overlay(message: &str, tone: EndgameTone) {
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

        let class = match tone {
            EndgameTone::Victory => "endgame-overlay victory",
            EndgameTone::Defeat => "endgame-overlay defeat",
            EndgameTone::Draw => "endgame-overlay draw",
        };
        overlay.set_class_name(class);

        let (title, crest) = match tone {
            EndgameTone::Victory => ("승리", "⛧"),
            EndgameTone::Defeat => ("패배", "✕"),
            EndgameTone::Draw => ("무승부", "◈"),
        };

        // Build inner HTML with safe text insertion for the message.
        // Title is a fixed Korean string (safe). Message uses set_text_content below.
        let html = format!(
            "<div class=\"endgame-content\">\
                <div class=\"endgame-crest\">{crest}</div>\
                <h1 class=\"endgame-title\">{title}</h1>\
                <p class=\"endgame-message\"></p>\
                <button class=\"endgame-btn\" \
                    onclick=\"this.closest('.endgame-overlay').remove()\">닫기</button>\
            </div>"
        );
        overlay.set_inner_html(&html);

        // Set message text safely (auto-escapes HTML entities).
        if let Ok(Some(el)) = overlay.query_selector(".endgame-message") {
            el.set_text_content(Some(message));
        }

        body.append_child(&overlay).ok();
    }

    // Suppress unused warnings on native builds.
    let _ = (message, tone);
}
