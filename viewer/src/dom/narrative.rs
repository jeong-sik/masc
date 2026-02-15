use bevy::prelude::*;
use wasm_bindgen::JsCast;

use crate::game::events::NarrativeReceived;

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
        entry.set_class_name(&format!("narrative-entry phase-{}", payload.phase));

        // Build inner content with optional speaker attribution
        let html = if let Some(ref speaker) = payload.speaker {
            format!(
                "<span class=\"narrative-speaker\">{}</span> {}",
                speaker, payload.text
            )
        } else {
            payload.text.clone()
        };
        entry.set_inner_html(&html);

        let _ = log_el.append_child(&entry);

        // Auto-scroll to the newest entry
        if let Ok(html_el) = entry.dyn_into::<web_sys::HtmlElement>() {
            html_el.scroll_into_view();
        }
    }
}
