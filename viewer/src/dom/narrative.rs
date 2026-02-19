use bevy::prelude::*;
use wasm_bindgen::closure::Closure;
use wasm_bindgen::JsCast;

use crate::game::events::NarrativeReceived;

use super::escape::{sanitize_text, scroll_to_bottom, trim_log};

fn normalize_phase_suffix(phase: &str) -> String {
    let mut out = String::with_capacity(phase.len());
    for ch in phase.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
        } else {
            out.push('-');
        }
    }
    let normalized = out.trim_matches('-');
    if normalized.is_empty() {
        "unknown".to_string()
    } else {
        normalized.to_string()
    }
}

fn is_debug_narrative(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("[timeout]") || lower.contains("[unavailable]")
}

fn debug_mode_enabled(document: &web_sys::Document) -> bool {
    document
        .get_element_by_id("dashboard")
        .and_then(|el| el.get_attribute("data-debug"))
        .map(|mode| mode != "off")
        .unwrap_or(true)
}

fn apply_debug_visibility(el: &web_sys::Element, debug_enabled: bool, is_debug_entry: bool) {
    let display = if !debug_enabled && is_debug_entry {
        "none"
    } else {
        "block"
    };
    if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
        let _ = html_el.style().set_property("display", display);
    }
}

fn toggle_selected_class(el: &web_sys::Element) {
    let current = el.class_name();
    let has_selected = current.split_whitespace().any(|cls| cls == "selected");
    let next = if has_selected {
        current
            .split_whitespace()
            .filter(|cls| *cls != "selected")
            .collect::<Vec<_>>()
            .join(" ")
    } else if current.trim().is_empty() {
        "selected".to_string()
    } else {
        format!("{} selected", current.trim())
    };
    el.set_class_name(next.trim());
}

fn bump_dedup_narrative(document: &web_sys::Document, sample: &str) {
    let Some(dashboard) = document.get_element_by_id("dashboard") else {
        return;
    };
    let next = dashboard
        .get_attribute("data-dedup-narrative")
        .and_then(|raw| raw.parse::<u64>().ok())
        .unwrap_or(0)
        .saturating_add(1);
    let _ = dashboard.set_attribute("data-dedup-narrative", &next.to_string());

    let mut lines = dashboard
        .get_attribute("data-dedup-samples-narrative")
        .unwrap_or_default()
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    let trimmed = sample.trim();
    if !trimmed.is_empty() {
        lines.push(trimmed.chars().take(160).collect());
    }
    if lines.len() > 24 {
        let drain = lines.len() - 24;
        lines.drain(0..drain);
    }
    let _ = dashboard.set_attribute("data-dedup-samples-narrative", &lines.join("\n"));
}

fn is_duplicate_narrative_entry(log_el: &web_sys::Element, dedup_key: &str) -> bool {
    let mut scanned = 0_u32;
    let mut cursor = log_el.last_element_child();
    while scanned < 40 {
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

/// Appends narrative entries to the #narrative-log DOM element.
pub fn update_narrative_dom(mut events: MessageReader<NarrativeReceived>) {
    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(log_el) = document.get_element_by_id("narrative-log") else {
        return;
    };
    let debug_enabled = debug_mode_enabled(&document);

    for NarrativeReceived(payload) in events.read() {
        let Ok(entry) = document.create_element("div") else {
            continue;
        };
        let phase_text = sanitize_text(&payload.phase);
        let phase_suffix = normalize_phase_suffix(&phase_text);
        entry.set_class_name(&format!("narrative-entry phase-{}", phase_suffix));
        let _ = entry.set_attribute("role", "button");
        let _ = entry.set_attribute("tabindex", "0");
        let _ = entry.set_attribute("title", "클릭하면 이 내러티브를 강조합니다.");
        let clean_text = sanitize_text(&payload.text);
        if clean_text.trim().is_empty() {
            continue;
        }
        let speaker_raw = payload
            .speaker
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("system");
        let dedup_key = format!(
            "{}|{}|{}|{}",
            payload.turn,
            phase_text.trim().to_ascii_lowercase(),
            speaker_raw.to_ascii_lowercase(),
            clean_text.trim()
        );
        if is_duplicate_narrative_entry(&log_el, &dedup_key) {
            bump_dedup_narrative(
                &document,
                &format!(
                    "t{} | {} | {} | {}",
                    payload.turn,
                    phase_text.trim(),
                    speaker_raw,
                    clean_text.trim()
                ),
            );
            continue;
        }
        let _ = entry.set_attribute("data-dedup-key", &dedup_key);
        if payload.turn > 0 {
            let _ = entry.set_attribute("data-turn", &payload.turn.to_string());
        }
        let is_debug_entry = is_debug_narrative(&clean_text);
        if is_debug_entry {
            let _ = entry.set_attribute("data-debug-entry", "1");
        }

        let speaker = payload
            .speaker
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(sanitize_text);

        if let Ok(meta_el) = document.create_element("div") {
            meta_el.set_class_name("narrative-meta");
            let meta_text = if let Some(speaker) = speaker.as_deref() {
                format!("{} · {}", phase_text, speaker)
            } else {
                phase_text.clone()
            };
            meta_el.set_text_content(Some(&meta_text));
            let _ = entry.append_child(&meta_el);
        }

        // Never insert streamed text via innerHTML.
        if let Some(speaker) = speaker.as_deref() {
            if let Ok(speaker_el) = document.create_element("span") {
                speaker_el.set_class_name("narrative-speaker");
                speaker_el.set_text_content(Some(speaker));
                let _ = entry.append_child(&speaker_el);
            }
        }
        if let Ok(text_el) = document.create_element("span") {
            text_el.set_class_name("narrative-text");
            let text = if speaker.is_some() {
                format!(" {}", clean_text.clone())
            } else {
                clean_text
            };
            text_el.set_text_content(Some(&text));
            let _ = entry.append_child(&text_el);
        }

        let clickable_entry = entry.clone();
        let click_cb = Closure::wrap(Box::new(move || {
            toggle_selected_class(&clickable_entry);
        }) as Box<dyn FnMut()>);
        let _ = entry.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", click_cb.as_ref().unchecked_ref())
        });
        click_cb.forget();

        let _ = log_el.append_child(&entry);
        apply_debug_visibility(&entry, debug_enabled, is_debug_entry);
        scroll_to_bottom(&log_el);
        trim_log(&log_el, 200);
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_phase_suffix;

    #[test]
    fn normalize_phase_suffix_handles_untrusted_input() {
        assert_eq!(
            normalize_phase_suffix("dm narration<script>alert(1)</script>"),
            "dm-narration-script-alert-1---script"
        );
    }

    #[test]
    fn normalize_phase_suffix_fallbacks_to_unknown() {
        assert_eq!(normalize_phase_suffix("   "), "unknown");
        assert_eq!(normalize_phase_suffix("<<<>>>"), "unknown");
    }
}
