#[cfg(target_arch = "wasm32")]
use crate::dom::escape::html_escape;
use crate::game::events::{
    CombatAttack, CombatDefense, InterventionApplied, InterventionSubmitted, KeeperUnavailable,
    PartySelected, PhaseChanged, WorkspaceCreated, WorkspaceStarted, SessionOutcome, SessionStarted,
    TurnActionResolved, TurnStarted,
};
use bevy::prelude::*;

#[allow(clippy::too_many_arguments)]
pub fn update_session_events_dom(
    mut party: MessageReader<PartySelected>,
    mut workspace_created: MessageReader<WorkspaceCreated>,
    mut workspace_started: MessageReader<WorkspaceStarted>,
    mut session_started: MessageReader<SessionStarted>,
    mut phase_changed: MessageReader<PhaseChanged>,
    mut turn_started: MessageReader<TurnStarted>,
    mut action_resolved: MessageReader<TurnActionResolved>,
    mut combat_attack: MessageReader<CombatAttack>,
    mut combat_defense: MessageReader<CombatDefense>,
    mut session_outcome: MessageReader<SessionOutcome>,
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
                p.selected_player_ids
                    .iter()
                    .map(|id| html_escape(id))
                    .collect::<Vec<_>>()
                    .join(", ")
            };
            append_entry(
                &doc,
                &log,
                "session-event",
                &format!(
                    "<span class=\"session-icon\">○</span> Party formed: {}",
                    ids
                ),
            );
        }

        for WorkspaceCreated(p) in workspace_created.read() {
            let preset = if p.preset.is_empty() {
                "default"
            } else {
                &p.preset
            };
            append_entry(
                &doc,
                &log,
                "session-event",
                &format!(
                    "<span class=\"session-icon\">○</span> Workspace created ({})",
                    html_escape(preset)
                ),
            );
        }

        for WorkspaceStarted(p) in workspace_started.read() {
            let status = if p.status.is_empty() {
                "started"
            } else {
                &p.status
            };
            append_entry(
                &doc,
                &log,
                "session-event session-start",
                &format!(
                    "<span class=\"session-icon\">▶</span> Adventure {} — {}",
                    html_escape(status),
                    html_escape(&p.workspace_id)
                ),
            );
        }

        for SessionStarted(p) in session_started.read() {
            let sid = if p.session_id.is_empty() {
                "?"
            } else {
                &p.session_id
            };
            append_entry(
                &doc,
                &log,
                "session-event",
                &format!(
                    "<span class=\"session-icon\">○</span> Session: {}",
                    html_escape(sid)
                ),
            );
        }

        for PhaseChanged(p) in phase_changed.read() {
            append_entry(
                &doc,
                &log,
                "turn-event",
                &format!(
                    "<span class=\"turn-icon\">◆</span> Phase → {} (Turn {})",
                    html_escape(&p.phase),
                    p.turn
                ),
            );
        }

        for TurnStarted(p) in turn_started.read() {
            append_entry(
                &doc,
                &log,
                "turn-event turn-start",
                &format!(
                    "<span class=\"turn-icon\">◆</span> Turn {} begins — {}",
                    p.turn,
                    html_escape(&p.phase)
                ),
            );
        }

        for TurnActionResolved(p) in action_resolved.read() {
            append_entry(
                &doc,
                &log,
                "action-result",
                &format!(
                    "<span class=\"action-icon\">✓</span> {} performed {} → {}",
                    html_escape(&p.actor_id),
                    html_escape(&p.action),
                    html_escape(&p.result)
                ),
            );
        }

        for CombatAttack(p) in combat_attack.read() {
            append_entry(
                &doc,
                &log,
                "action-result combat-attack fx-attack",
                &format!(
                    "<span class=\"event-badge badge-attack\">⚔ ATTACK</span>\
                     <span class=\"event-main\">{}</span>\
                     <span class=\"event-sep\">→</span>\
                     <span class=\"event-detail\">{}</span>",
                    html_escape(&p.actor_id),
                    html_escape(&p.action)
                ),
            );
            set_event_beacon(
                &doc,
                "attack",
                "공격",
                &format!("{} · {}", p.actor_id, p.action),
            );
        }

        for CombatDefense(p) in combat_defense.read() {
            append_entry(
                &doc,
                &log,
                "action-result combat-defense fx-defense",
                &format!(
                    "<span class=\"event-badge badge-defense\">🛡 DEFENSE</span>\
                     <span class=\"event-main\">{}</span>\
                     <span class=\"event-sep\">·</span>\
                     <span class=\"event-detail\">{}</span>",
                    html_escape(&p.actor_id),
                    html_escape(&p.method)
                ),
            );
            set_event_beacon(
                &doc,
                "defense",
                "방어",
                &format!("{} · {}", p.actor_id, p.method),
            );
        }

        for SessionOutcome(p) in session_outcome.read() {
            let (tone_class, label, icon) = match p.outcome.trim().to_ascii_lowercase().as_str() {
                "victory" => ("outcome-victory", "승리", "🏆"),
                "defeat" => ("outcome-defeat", "패배", "☠"),
                _ => ("outcome-draw", "무승부", "⚖"),
            };
            let summary = if p.summary.trim().is_empty() {
                format!("세션 종료 · {}", label)
            } else {
                p.summary.trim().to_string()
            };
            append_entry(
                &doc,
                &log,
                &format!("session-event session-outcome {}", tone_class),
                &format!(
                    "<span class=\"event-badge badge-outcome\">{} {}</span>\
                     <span class=\"event-detail\">{}</span>",
                    icon,
                    label,
                    html_escape(&summary)
                ),
            );
            set_event_beacon(&doc, &p.outcome, label, &summary);
        }

        for InterventionSubmitted(p) in intervention_sub.read() {
            let target = if p.target.is_empty() { "" } else { &p.target };
            append_entry(
                &doc,
                &log,
                "intervention-event",
                &format!(
                    "<span class=\"intervention-icon\">⚑</span> Intervention: {} {} — {}",
                    html_escape(&p.intervention_type),
                    if target.is_empty() {
                        String::new()
                    } else {
                        format!("→ {}", html_escape(target))
                    },
                    html_escape(&p.description)
                ),
            );
        }

        for InterventionApplied(p) in intervention_app.read() {
            let target = if p.target.is_empty() { "" } else { &p.target };
            append_entry(
                &doc,
                &log,
                "intervention-event intervention-applied",
                &format!(
                    "<span class=\"intervention-icon\">⚑</span> Applied: {} {} — {}",
                    html_escape(&p.intervention_type),
                    if target.is_empty() {
                        String::new()
                    } else {
                        format!("→ {}", html_escape(target))
                    },
                    html_escape(&p.description)
                ),
            );
        }

        for KeeperUnavailable(p) in keeper_unavail.read() {
            let reason = if p.reason.is_empty() {
                "no reason given"
            } else {
                &p.reason
            };
            append_entry(
                &doc,
                &log,
                "keeper-warning",
                &format!(
                    "<span class=\"warning-icon\">⚠</span> Keeper {} unavailable — {}",
                    html_escape(&p.keeper),
                    html_escape(reason)
                ),
            );
        }
    }

    // Suppress unused-variable warnings on non-wasm targets
    let _ = (
        &mut party,
        &mut workspace_created,
        &mut workspace_started,
        &mut session_started,
        &mut phase_changed,
        &mut turn_started,
        &mut action_resolved,
        &mut combat_attack,
        &mut combat_defense,
        &mut session_outcome,
        &mut intervention_sub,
        &mut intervention_app,
        &mut keeper_unavail,
    );
}

#[cfg(target_arch = "wasm32")]
fn append_entry(doc: &web_sys::Document, log: &web_sys::Element, class: &str, inner_html: &str) {
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

#[cfg(target_arch = "wasm32")]
fn beacon_tone(raw: &str) -> &'static str {
    match raw.trim().to_ascii_lowercase().as_str() {
        "victory" => "victory",
        "defeat" => "defeat",
        "draw" => "draw",
        "attack" => "attack",
        "defense" => "defense",
        _ => "info",
    }
}

#[cfg(target_arch = "wasm32")]
fn set_event_beacon(doc: &web_sys::Document, tone: &str, title: &str, detail: &str) {
    let Some(el) = doc.get_element_by_id("event-beacon") else {
        return;
    };
    let tone = beacon_tone(tone);
    let icon = match tone {
        "attack" => "⚔",
        "defense" => "🛡",
        "victory" => "🏆",
        "defeat" => "☠",
        "draw" => "⚖",
        _ => "✶",
    };
    el.set_class_name(&format!("event-beacon tone-{tone}"));
    el.set_inner_html(&format!(
        "<span class=\"beacon-icon\">{}</span>\
         <span class=\"beacon-copy\">\
           <span class=\"beacon-title\">{}</span>\
           <span class=\"beacon-detail\">{}</span>\
         </span>",
        icon,
        html_escape(title),
        html_escape(detail)
    ));
}
