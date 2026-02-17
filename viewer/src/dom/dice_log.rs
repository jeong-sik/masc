use bevy::prelude::*;

use crate::game::events::DiceRolled;

use super::escape::{html_escape, sanitize_text, trim_log};

/// Maps dice result tiers to CSS class suffixes.
fn tier_class(result: &str) -> &'static str {
    match result {
        "critical_fail" => "tier-critical_fail",
        "fail" => "tier-fail",
        "partial" | "partial_success" => "tier-partial",
        "success" => "tier-success",
        "great" | "great_success" => "tier-great",
        "miracle" => "tier-miracle",
        _ => "tier-success",
    }
}

/// Maps dice result tiers to Korean display labels.
fn tier_label(result: &str) -> &'static str {
    match result {
        "critical_fail" => "대참사",
        "fail" => "실패",
        "partial" | "partial_success" => "부분 성공",
        "success" => "성공",
        "great" | "great_success" => "대성공",
        "miracle" => "기적",
        _ => "알 수 없음",
    }
}

/// Appends dice roll entries to the #dice-log DOM element.
pub fn update_dice_log_dom(mut events: MessageReader<DiceRolled>) {
    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(log_el) = document.get_element_by_id("dice-log") else {
        return;
    };

    for DiceRolled(payload) in events.read() {
        let Ok(entry) = document.create_element("div") else {
            continue;
        };
        let tier = tier_class(&payload.result);
        entry.set_class_name(&format!("dice-entry {}", tier));
        let character = html_escape(&sanitize_text(&payload.character));
        let action = html_escape(&sanitize_text(&payload.action));
        let note_html = payload
            .note
            .as_deref()
            .map(|n| format!("<div class=\"dice-note\">{}</div>", html_escape(&sanitize_text(n))))
            .unwrap_or_default();

        entry.set_inner_html(&format!(
            r#"<div class="dice-character">{}</div>
<div class="dice-action">{}</div>
<div class="dice-result">{}</div>
<div class="dice-detail">d20: {} + {} = {} (DC {})</div>
<div class="dice-tier">{}</div>
{}"#,
            character,
            action,
            payload.total,
            payload.d20,
            payload.bonus,
            payload.total,
            payload.dc,
            tier_label(&payload.result),
            note_html,
        ));

        let _ = log_el.append_child(&entry);
        trim_log(&log_el, 120);

        // Auto-scroll horizontally to the newest entry
        let scroll_width = log_el.scroll_width();
        log_el.set_scroll_left(scroll_width);
    }
}
