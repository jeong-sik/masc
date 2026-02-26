//! Endgame detection and overlay rendering.
//!
//! Canonical detection path:
//! 1. **Session outcome** — `session.outcome` SSE event

use bevy::prelude::*;
use std::sync::atomic::Ordering;

use crate::game::events::SessionOutcome;
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

/// Monitors canonical session outcome and triggers the endgame overlay once.
pub fn detect_endgame(
    runner: Option<Res<RoundRunner>>,
    mut outcomes: MessageReader<SessionOutcome>,
    mut endgame: ResMut<EndgameState>,
) {
    if endgame.triggered {
        // Drain the reader even when already triggered to avoid stale buffers.
        for _ in outcomes.read() {}
        return;
    }

    // Canonical session outcome.
    if let Some(SessionOutcome(payload)) = outcomes.read().next() {
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
