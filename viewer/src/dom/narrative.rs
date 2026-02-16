use bevy::prelude::*;
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

/// Appends narrative entries to the #narrative-log DOM element.
pub fn update_narrative_dom(mut events: MessageReader<NarrativeReceived>) {
    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(log_el) = document.get_element_by_id("narrative-log") else {
        return;
    };

    for NarrativeReceived(payload) in events.read() {
        let Ok(entry) = document.create_element("div") else {
            continue;
        };
        let phase_suffix = normalize_phase_suffix(&payload.phase);
        entry.set_class_name(&format!("narrative-entry phase-{}", phase_suffix));

        // Never insert streamed text via innerHTML.
        if let Some(speaker) = payload
            .speaker
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            if let Ok(speaker_el) = document.create_element("span") {
                speaker_el.set_class_name("narrative-speaker");
                speaker_el.set_text_content(Some(speaker));
                let _ = entry.append_child(&speaker_el);
            }
        }
        if let Ok(text_el) = document.create_element("span") {
            text_el.set_class_name("narrative-text");
            let text = if payload.speaker.as_deref().is_some() {
                format!(" {}", payload.text)
            } else {
                payload.text.clone()
            };
            text_el.set_text_content(Some(&text));
            let _ = entry.append_child(&text_el);
        }

        let _ = log_el.append_child(&entry);

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
