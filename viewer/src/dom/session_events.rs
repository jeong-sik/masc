use bevy::prelude::*;
use crate::game::events::{
    InterventionApplied, InterventionSubmitted, KeeperUnavailable,
    PartySelected, PhaseChanged, RoomCreated, RoomStarted,
    SessionStarted, TurnActionResolved, TurnStarted,
};
#[cfg(target_arch = "wasm32")]
use crate::dom::escape::html_escape;

pub fn update_session_events_dom(
    mut party: MessageReader<PartySelected>,
    mut room_created: MessageReader<RoomCreated>,
    mut room_started: MessageReader<RoomStarted>,
    mut session_started: MessageReader<SessionStarted>,
    mut phase_changed: MessageReader<PhaseChanged>,
    mut turn_started: MessageReader<TurnStarted>,
    mut action_resolved: MessageReader<TurnActionResolved>,
    mut intervention_sub: MessageReader<InterventionSubmitted>,
    mut intervention_app: MessageReader<InterventionApplied>,
    mut keeper_unavail: MessageReader<KeeperUnavailable>,
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

        for PartySelected(p) in party.read() {
            let ids = if p.selected_player_ids.is_empty() {
                "...".to_string()
            } else {
                p.selected_player_ids.iter()
                    .map(|id| html_escape(id))
                    .collect::<Vec<_>>()
                    .join(", ")
            };
            append_entry(&doc, &log, "session-event",
                &format!("<span class=\"session-icon\">\u{25cb}</span> Party formed: {}", ids));
        }

        for RoomCreated(p) in room_created.read() {
            let preset = if p.preset.is_empty() { "default" } else { &p.preset };
            append_entry(&doc, &log, "session-event",
                &format!("<span class=\"session-icon\">\u{25cb}</span> Room created ({})",
                    html_escape(preset)));
        }

        for RoomStarted(p) in room_started.read() {
            let status = if p.status.is_empty() { "started" } else { &p.status };
            append_entry(&doc, &log, "session-event session-start",
                &format!("<span class=\"session-icon\">\u{25b6}</span> Adventure {} \u{2014} {}",
                    html_escape(status), html_escape(&p.room_id)));
        }

        for SessionStarted(p) in session_started.read() {
            let sid = if p.session_id.is_empty() { "?" } else { &p.session_id };
            append_entry(&doc, &log, "session-event",
                &format!("<span class=\"session-icon\">\u{25cb}</span> Session: {}",
                    html_escape(sid)));
        }

        for PhaseChanged(p) in phase_changed.read() {
            append_entry(&doc, &log, "turn-event",
                &format!("<span class=\"turn-icon\">\u{25c6}</span> Phase \u{2192} {} (Turn {})",
                    html_escape(&p.phase), p.turn));
        }

        for TurnStarted(p) in turn_started.read() {
            append_entry(&doc, &log, "turn-event turn-start",
                &format!("<span class=\"turn-icon\">\u{25c6}</span> Turn {} begins \u{2014} {}",
                    p.turn, html_escape(&p.phase)));
        }

        for TurnActionResolved(p) in action_resolved.read() {
            append_entry(&doc, &log, "action-result",
                &format!("<span class=\"action-icon\">\u{2713}</span> {} performed {} \u{2192} {}",
                    html_escape(&p.actor_id), html_escape(&p.action), html_escape(&p.result)));
        }

        for InterventionSubmitted(p) in intervention_sub.read() {
            let target = if p.target.is_empty() { "" } else { &p.target };
            append_entry(&doc, &log, "intervention-event",
                &format!("<span class=\"intervention-icon\">\u{2691}</span> Intervention: {} {} \u{2014} {}",
                    html_escape(&p.intervention_type),
                    if target.is_empty() { String::new() } else { format!("\u{2192} {}", html_escape(target)) },
                    html_escape(&p.description)));
        }

        for InterventionApplied(p) in intervention_app.read() {
            let target = if p.target.is_empty() { "" } else { &p.target };
            append_entry(&doc, &log, "intervention-event intervention-applied",
                &format!("<span class=\"intervention-icon\">\u{2691}</span> Applied: {} {} \u{2014} {}",
                    html_escape(&p.intervention_type),
                    if target.is_empty() { String::new() } else { format!("\u{2192} {}", html_escape(target)) },
                    html_escape(&p.description)));
        }

        for KeeperUnavailable(p) in keeper_unavail.read() {
            let reason = if p.reason.is_empty() { "no reason given" } else { &p.reason };
            append_entry(&doc, &log, "keeper-warning",
                &format!("<span class=\"warning-icon\">\u{26a0}</span> Keeper {} unavailable \u{2014} {}",
                    html_escape(&p.keeper), html_escape(reason)));
        }
    }

    // Suppress unused-variable warnings on non-wasm targets
    let _ = (&mut party, &mut room_created, &mut room_started, &mut session_started,
             &mut phase_changed, &mut turn_started, &mut action_resolved,
             &mut intervention_sub, &mut intervention_app, &mut keeper_unavail);
}

#[cfg(target_arch = "wasm32")]
fn append_entry(
    doc: &web_sys::Document,
    log: &web_sys::Element,
    class: &str,
    inner_html: &str,
) {
    if let Ok(div) = doc.create_element("div") {
        div.set_class_name(&format!("narrative-entry {}", class));
        div.set_inner_html(inner_html);
        log.append_child(&div).ok();
        // Trim to 200 entries
        while log.child_element_count() > 200 {
            if let Some(first) = log.first_element_child() {
                log.remove_child(&first).ok();
            } else {
                break;
            }
        }
        // Auto-scroll
        log.set_scroll_top(log.scroll_height());
    }
}
