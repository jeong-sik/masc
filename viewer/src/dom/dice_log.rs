use bevy::prelude::*;
use wasm_bindgen::closure::Closure;
use wasm_bindgen::JsCast;

use crate::game::events::DiceRolled;

use super::escape::{html_escape, sanitize_text, trim_log};
use super::session_history::sync_history_focus_from_dashboard;

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

fn current_workspace_id(document: &web_sys::Document) -> String {
    document
        .get_element_by_id("dashboard")
        .and_then(|el| el.get_attribute("data-workspace-id"))
        .map(|raw| sanitize_text(raw.trim()))
        .filter(|value| !value.is_empty())
        .unwrap_or_default()
}

fn is_duplicate_dice_entry(log_el: &web_sys::Element, dedup_key: &str) -> bool {
    let mut scanned = 0_u32;
    let mut cursor = log_el.last_element_child();
    while scanned < 50 {
        let Some(el) = cursor else {
            break;
        };
        if el
            .get_attribute("data-dedup-key")
            .map(|value| value == dedup_key)
            .unwrap_or(false)
        {
            return true;
        }
        cursor = el.previous_element_sibling();
        scanned += 1;
    }
    false
}

/// Appends dice roll entries to the #dice-log DOM element.
pub fn update_dice_log_dom(mut events: MessageReader<DiceRolled>) {
    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(log_el) = document.get_element_by_id("dice-log") else {
        return;
    };
    let fallback_workspace_id = current_workspace_id(&document);

    for DiceRolled(payload) in events.read() {
        // Phase 3-2: Dice roll arithmetic validation
        // Skip when total==0 (serde default: server omitted the field).
        let expected_total = payload.d20 + payload.bonus;
        if payload.total != expected_total && payload.total != 0 {
            log::warn!(
                "Dice roll arithmetic mismatch for {}: total={} but d20({}) + bonus({}) = {}",
                payload.character,
                payload.total,
                payload.d20,
                payload.bonus,
                expected_total
            );
        }

        let Ok(entry) = document.create_element("div") else {
            continue;
        };

        // Prefer server-provided tier over the legacy `result` field.
        let effective_tier = payload
            .tier
            .as_deref()
            .unwrap_or(&payload.result);
        let tier = tier_class(effective_tier);
        entry.set_class_name(&format!("dice-entry {}", tier));

        let workspace_id = if payload.workspace_id.trim().is_empty() {
            fallback_workspace_id.clone()
        } else {
            sanitize_text(payload.workspace_id.trim())
        };

        let character = html_escape(&sanitize_text(&payload.character));
        let action = html_escape(&sanitize_text(&payload.action));
        let note_clean = payload
            .note
            .as_deref()
            .map(sanitize_text)
            .unwrap_or_default();
        let note_html = if note_clean.trim().is_empty() {
            String::new()
        } else {
            format!(
                "<div class=\"dice-note\">{}</div>",
                html_escape(&note_clean)
            )
        };

        let dedup_key = format!(
            "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}",
            workspace_id.to_ascii_lowercase(),
            payload.turn,
            payload.character.trim().to_ascii_lowercase(),
            payload.action.trim().to_ascii_lowercase(),
            payload.d20,
            payload.bonus,
            payload.total,
            payload.dc,
            payload.result.trim().to_ascii_lowercase(),
            note_clean.trim()
        );

        if is_duplicate_dice_entry(&log_el, &dedup_key) {
            continue;
        }

        let _ = entry.set_attribute("data-dedup-key", &dedup_key);
        if !workspace_id.is_empty() {
            let _ = entry.set_attribute("data-workspace-id", &workspace_id);
        }
        if payload.turn > 0 {
            let _ = entry.set_attribute("data-turn", &payload.turn.to_string());
        }
        let _ = entry.set_attribute("role", "button");
        let _ = entry.set_attribute("tabindex", "0");
        let _ = entry.set_attribute("title", "클릭하면 해당 턴을 히스토리에서 강조합니다.");

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
            // Use server label if available, otherwise derive from tier.
            payload.label.as_deref().unwrap_or_else(|| tier_label(effective_tier)),
            note_html,
        ));

        let clickable_entry = entry.clone();
        let click_cb = Closure::wrap(Box::new(move || {
            let Some(document) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            let Some(dashboard) = document.get_element_by_id("dashboard") else {
                return;
            };
            if let Some(workspace_id) = clickable_entry.get_attribute("data-workspace-id") {
                if !workspace_id.trim().is_empty() {
                    let _ = dashboard.set_attribute("data-focus-workspace", workspace_id.trim());
                }
            }
            if let Some(turn) = clickable_entry.get_attribute("data-turn") {
                if !turn.trim().is_empty() {
                    let _ = dashboard.set_attribute("data-focus-turn", turn.trim());
                }
            }
            sync_history_focus_from_dashboard(&document);
        }) as Box<dyn FnMut()>);
        let _ = entry.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", click_cb.as_ref().unchecked_ref())
        });
        click_cb.forget();

        let _ = log_el.append_child(&entry);
        trim_log(&log_el, 120);

        // Auto-scroll horizontally to the newest entry
        let scroll_width = log_el.scroll_width();
        log_el.set_scroll_left(scroll_width);
    }
}
