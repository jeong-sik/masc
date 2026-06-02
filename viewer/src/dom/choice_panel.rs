use bevy::prelude::*;

use crate::game::events::{ChoiceAvailable, ChoiceResolved, CombatStarted};

#[cfg(target_arch = "wasm32")]
use super::escape::{html_escape, scroll_to_bottom, trim_log};

/// Renders choice and combat events into the `#narrative-log` DOM element.
/// Uses the same append-child pattern as `narrative.rs` and `dice_log.rs`.
pub fn update_choice_dom(
    mut choices: MessageReader<ChoiceAvailable>,
    mut resolutions: MessageReader<ChoiceResolved>,
    mut combats: MessageReader<CombatStarted>,
) {
    #[cfg(target_arch = "wasm32")]
    {
        let doc = match web_sys::window().and_then(|w| w.document()) {
            Some(d) => d,
            None => return,
        };
        let log = match doc.get_element_by_id("narrative-log") {
            Some(el) => el,
            None => return,
        };

        for ChoiceAvailable(p) in choices.read() {
            let Ok(div) = doc.create_element("div") else {
                continue;
            };
            div.set_class_name("narrative-entry choice-block");
            let opts: String = p
                .options
                .iter()
                .map(|o| format!("<li class=\"choice-option\">{}</li>", html_escape(o)))
                .collect();
            div.set_inner_html(&format!(
                "<span class=\"choice-character\">{}</span> \
                 <span class=\"choice-desc\">{}</span>\
                 <ul class=\"choice-list\">{}</ul>",
                html_escape(&p.character),
                html_escape(&p.description),
                opts
            ));
            let _ = log.append_child(&div);
            scroll_to_bottom(&log);
            trim_log(&log, 200);
        }

        for ChoiceResolved(p) in resolutions.read() {
            let Ok(div) = doc.create_element("div") else {
                continue;
            };
            div.set_class_name("narrative-entry choice-resolved");
            let text = format!("{} chose: {}", &p.character, &p.description);
            div.set_text_content(Some(&text));
            let _ = log.append_child(&div);
            scroll_to_bottom(&log);
            trim_log(&log, 200);
        }

        for CombatStarted(p) in combats.read() {
            let Ok(div) = doc.create_element("div") else {
                continue;
            };
            div.set_class_name("narrative-entry combat-block");
            let enemies = if p.enemies.is_empty() {
                "???".to_string()
            } else {
                p.enemies.join(", ")
            };
            div.set_inner_html(&format!(
                "<span class=\"combat-alert\">\u{2694}\u{fe0f} Combat</span> {} \u{2014} enemies: {}",
                html_escape(&p.area),
                html_escape(&enemies)
            ));
            let _ = log.append_child(&div);
            scroll_to_bottom(&log);
            trim_log(&log, 200);
        }
    }

    // Suppress unused-variable warnings on non-wasm targets
    let _ = (&mut choices, &mut resolutions, &mut combats);
}
