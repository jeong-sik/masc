use bevy::prelude::*;

use crate::game::events::{AreaMoved, CharacterDied, ItemAcquired};

use super::escape::{html_escape, scroll_to_bottom, trim_log};

/// Renders AreaMoved, ItemAcquired, and CharacterDied events into the
/// `#narrative-log` DOM element as styled narrative blocks.
pub fn update_gameplay_events_dom(
    mut area_events: MessageReader<AreaMoved>,
    mut item_events: MessageReader<ItemAcquired>,
    mut death_events: MessageReader<CharacterDied>,
) {
    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(log_el) = document.get_element_by_id("narrative-log") else {
        return;
    };

    for AreaMoved(payload) in area_events.read() {
        let Ok(entry) = document.create_element("div") else {
            continue;
        };
        entry.set_class_name("gameplay-event move-block");
        entry.set_inner_html(&format!(
            "\u{1f6b6} <strong>{}</strong> moved to <em>{}</em>",
            html_escape(&payload.character),
            html_escape(&payload.to_area),
        ));
        let _ = log_el.append_child(&entry);
    }

    for ItemAcquired(payload) in item_events.read() {
        let Ok(entry) = document.create_element("div") else {
            continue;
        };
        entry.set_class_name("gameplay-event item-block");
        entry.set_inner_html(&format!(
            "\u{2728} <strong>{}</strong> acquired <strong>{}</strong>",
            html_escape(&payload.character),
            html_escape(&payload.item),
        ));
        let _ = log_el.append_child(&entry);
    }

    for CharacterDied(payload) in death_events.read() {
        let Ok(entry) = document.create_element("div") else {
            continue;
        };
        entry.set_class_name("gameplay-event death-block");
        entry.set_inner_html(&format!(
            "\u{1f480} <strong>{}</strong> has fallen \u{2014} {}",
            html_escape(&payload.character),
            html_escape(&payload.cause),
        ));
        let _ = log_el.append_child(&entry);
    }

    scroll_to_bottom(&log_el);
    trim_log(&log_el, 200);
}
