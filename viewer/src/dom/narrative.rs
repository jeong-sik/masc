use bevy::prelude::*;
use wasm_bindgen::closure::Closure;
use wasm_bindgen::JsCast;

use crate::game::events::NarrativeReceived;

fn normalize_phase_suffix(phase: &str) -> String {
    let mut out = String::with_capacity(phase.len());
    for ch in phase.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
        } else if ch == '-' || ch == '_' || ch.is_whitespace() {
            out.push('-');
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

fn sanitize_text(raw: &str) -> String {
    raw.chars()
        .filter(|ch| {
            let code = *ch as u32;
            *ch != '\u{feff}'
                && *ch != '\u{fffd}'
                && !(code <= 0x08 || code == 0x0b || code == 0x0c || (0x0e..=0x1f).contains(&code))
        })
        .collect()
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

fn trim_narrative_log(log_el: &web_sys::Element, max_entries: u32) {
    while log_el.child_element_count() > max_entries {
        let Some(first) = log_el.first_element_child() else {
            break;
        };
        let _ = log_el.remove_child(&first);
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
        trim_narrative_log(&log_el, 180);

        // Auto-scroll to the newest entry
        if let Ok(html_el) = entry.dyn_into::<web_sys::HtmlElement>() {
            html_el.scroll_into_view();
        }
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
