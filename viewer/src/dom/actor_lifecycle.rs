use bevy::prelude::*;

use crate::game::events::{
    ActorClaimed, ActorDeleted, ActorReleased, ActorSpawned, SceneTransitioned,
};

#[cfg(target_arch = "wasm32")]
use crate::dom::escape::html_escape;

pub fn update_actor_lifecycle_dom(
    mut spawns: MessageReader<ActorSpawned>,
    mut deletes: MessageReader<ActorDeleted>,
    mut claims: MessageReader<ActorClaimed>,
    mut releases: MessageReader<ActorReleased>,
    mut scenes: MessageReader<SceneTransitioned>,
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

        for ActorSpawned(p) in spawns.read() {
            let div = doc
                .create_element("div")
                .expect("create div for actor-spawn");
            div.set_class_name("narrative-entry actor-spawn");
            let name = match p.name.as_deref() {
                Some(n) if !n.is_empty() => n,
                _ => &p.actor_id,
            };
            let class_info = match p.class.as_deref() {
                Some(c) if !c.is_empty() => format!(" ({})", html_escape(c)),
                _ => String::new(),
            };
            div.set_inner_html(&format!(
                "<span class=\"actor-icon\">+</span> <strong>{}</strong>{} joined the adventure",
                html_escape(name),
                class_info,
            ));
            log.append_child(&div).ok();
        }

        for ActorDeleted(p) in deletes.read() {
            let div = doc
                .create_element("div")
                .expect("create div for actor-delete");
            div.set_class_name("narrative-entry actor-delete");
            let name = match p.name.as_deref() {
                Some(n) if !n.is_empty() => n,
                _ => &p.actor_id,
            };
            div.set_inner_html(&format!(
                "<span class=\"actor-icon\">-</span> <strong>{}</strong> has left the adventure",
                html_escape(name),
            ));
            log.append_child(&div).ok();
        }

        for ActorClaimed(p) in claims.read() {
            let div = doc
                .create_element("div")
                .expect("create div for actor-claim");
            div.set_class_name("narrative-entry actor-claim");
            let name = match p.name.as_deref() {
                Some(n) if !n.is_empty() => n,
                _ => &p.actor_id,
            };
            let keeper = match p.keeper.as_deref() {
                Some(k) if !k.is_empty() => k,
                _ => "a keeper",
            };
            div.set_inner_html(&format!(
                "<span class=\"actor-icon\">&gt;</span> <strong>{}</strong> is now controlled by {}",
                html_escape(name),
                html_escape(keeper),
            ));
            log.append_child(&div).ok();
        }

        for ActorReleased(p) in releases.read() {
            let div = doc
                .create_element("div")
                .expect("create div for actor-release");
            div.set_class_name("narrative-entry actor-release");
            let name = match p.name.as_deref() {
                Some(n) if !n.is_empty() => n,
                _ => &p.actor_id,
            };
            div.set_inner_html(&format!(
                "<span class=\"actor-icon\">&lt;</span> <strong>{}</strong> is now uncontrolled",
                html_escape(name),
            ));
            log.append_child(&div).ok();
        }

        for SceneTransitioned(p) in scenes.read() {
            let div = doc
                .create_element("div")
                .expect("create div for scene-transition");
            div.set_class_name("narrative-entry scene-transition");
            let desc = if p.description.is_empty() {
                String::new()
            } else {
                format!(" — {}", html_escape(&p.description))
            };
            div.set_inner_html(&format!(
                "<span class=\"scene-icon\">*</span> Scene: {} &rarr; {}{}",
                html_escape(&p.from_scene),
                html_escape(&p.to_scene),
                desc,
            ));
            log.append_child(&div).ok();
        }

        // Trim log
        while log.child_element_count() > 200 {
            if let Some(first) = log.first_element_child() {
                let _ = log.remove_child(&first);
            } else {
                break;
            }
        }

        // Auto-scroll
        log.set_scroll_top(log.scroll_height());
    }

    // Consume remaining events on non-WASM targets
    let _ = (
        &mut spawns,
        &mut deletes,
        &mut claims,
        &mut releases,
        &mut scenes,
    );
}
