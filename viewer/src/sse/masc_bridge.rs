use bevy::prelude::*;

use super::masc_client::MascSseReceiver;

/// A single MASC event log entry.
#[allow(dead_code)]
pub struct MascLogEntry {
    pub timestamp: f64,
    pub event_type: String,
    pub summary: String,
}

/// Resource holding MASC event state for DOM rendering.
#[derive(Resource, Default)]
pub struct MascEventLog {
    pub entries: Vec<MascLogEntry>,
    pub agent_count: u32,
    pub task_count: u32,
}

/// Lightweight JSON field extractor.
/// Finds `"key": "value"` or `"key": number` in a JSON string.
/// No serde dependency needed — MASC events have simple flat structures.
fn extract_field<'a>(json: &'a str, key: &str) -> Option<&'a str> {
    let pattern = format!("\"{}\"", key);
    let key_pos = json.find(&pattern)?;
    let after_key = &json[key_pos + pattern.len()..];

    // Skip optional whitespace and colon
    let after_colon = after_key.trim_start().strip_prefix(':')?;
    let trimmed = after_colon.trim_start();

    if trimmed.starts_with('"') {
        // String value: find closing quote
        let value_start = 1; // skip opening quote
        let rest = &trimmed[value_start..];
        let end = rest.find('"')?;
        Some(&rest[..end])
    } else {
        // Non-string value (number, bool): find delimiter
        let end = trimmed
            .find(|c: char| c == ',' || c == '}' || c == ']' || c.is_whitespace())
            .unwrap_or(trimmed.len());
        Some(trimmed[..end].trim())
    }
}

/// Each frame, drain the MASC SSE message buffer and update DOM panels.
/// MASC events render as text in HTML panels, NOT as typed Bevy events.
pub fn poll_masc_events(
    receiver: Option<Res<MascSseReceiver>>,
    mut event_log: ResMut<MascEventLog>,
) {
    let Some(receiver) = receiver else { return };

    let mut msgs = match receiver.messages.lock() {
        Ok(guard) => guard,
        Err(_) => return,
    };

    if msgs.is_empty() {
        return;
    }

    let now = 0.0_f64; // Timestamp placeholder — no js_sys::Date dependency needed

    for (event_type, data) in msgs.drain(..) {
        match event_type.as_str() {
            "broadcast" => {
                let message = extract_field(&data, "message").unwrap_or("(no message)");
                let agent = extract_field(&data, "agent_name").unwrap_or("unknown");
                let summary = format!("[{}] {}", agent, message);

                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "broadcast".to_string(),
                    summary: summary.clone(),
                });

                update_monitor_events(&summary);
                update_social_feed(&summary);

                log::info!("MASC broadcast: {}", summary);
            }
            "heartbeat" => {
                log::debug!("MASC heartbeat received");
            }
            "agent_joined" => {
                let agent = extract_field(&data, "agent_name").unwrap_or("unknown");
                event_log.agent_count = event_log.agent_count.saturating_add(1);

                let summary = format!("{} joined", agent);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "agent_joined".to_string(),
                    summary: summary.clone(),
                });

                update_monitor_agents(event_log.agent_count, &summary);

                log::info!(
                    "MASC agent joined: {} (total: {})",
                    agent,
                    event_log.agent_count
                );
            }
            "agent_left" => {
                let agent = extract_field(&data, "agent_name").unwrap_or("unknown");
                event_log.agent_count = event_log.agent_count.saturating_sub(1);

                let summary = format!("{} left", agent);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "agent_left".to_string(),
                    summary: summary.clone(),
                });

                update_monitor_agents(event_log.agent_count, &summary);

                log::info!(
                    "MASC agent left: {} (total: {})",
                    agent,
                    event_log.agent_count
                );
            }
            "task_update" => {
                let task_id = extract_field(&data, "task_id").unwrap_or("?");
                let status = extract_field(&data, "status").unwrap_or("unknown");

                let summary = format!("Task {} -> {}", task_id, status);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "task_update".to_string(),
                    summary: summary.clone(),
                });

                // Crude task count tracking based on status
                match status {
                    "claimed" => {
                        event_log.task_count = event_log.task_count.saturating_add(1);
                    }
                    "done" | "cancelled" => {
                        event_log.task_count = event_log.task_count.saturating_sub(1);
                    }
                    _ => {}
                }

                update_monitor_tasks(event_log.task_count, &summary);

                log::info!("MASC task update: {}", summary);
            }
            "endpoint" => {
                let summary = format!("endpoint: {}", &data);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "endpoint".to_string(),
                    summary,
                });

                log::info!("MASC endpoint info received");
            }

            // ─── Council (MAGI Deliberation) ─────────────
            "decision_issue" => {
                let title = extract_field(&data, "title").unwrap_or("untitled");
                let urgency = extract_field(&data, "urgency").unwrap_or("normal");
                let summary = format!("[ISSUE] {} (urgency: {})", title, urgency);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "decision_issue".to_string(),
                    summary: summary.clone(),
                });
                update_council_deliberation(&summary);
                log::info!("MASC council: {}", summary);
            }
            "decision_option" => {
                let label = extract_field(&data, "label").unwrap_or("?");
                let proposed_by = extract_field(&data, "proposed_by").unwrap_or("unknown");
                let summary = format!("[OPTION] {} by {}", label, proposed_by);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "decision_option".to_string(),
                    summary: summary.clone(),
                });
                update_council_deliberation(&summary);
                log::info!("MASC council: {}", summary);
            }
            "decision_argument" => {
                let agent = extract_field(&data, "agent").unwrap_or("unknown");
                let position = extract_field(&data, "position").unwrap_or("neutral");
                let reasoning = extract_field(&data, "reasoning").unwrap_or("...");
                let summary = format!("[{}] {}: {}", position.to_uppercase(), agent, reasoning);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "decision_argument".to_string(),
                    summary: summary.clone(),
                });
                update_council_deliberation(&summary);
                log::info!("MASC council: {}", summary);
            }
            "decision_vote" => {
                let agent = extract_field(&data, "agent").unwrap_or("unknown");
                let option_id = extract_field(&data, "option_id").unwrap_or("?");
                let weight = extract_field(&data, "weight").unwrap_or("1");
                let summary = format!("[VOTE] {} -> {} (weight: {})", agent, option_id, weight);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "decision_vote".to_string(),
                    summary: summary.clone(),
                });
                update_council_deliberation(&summary);
                log::info!("MASC council: {}", summary);
            }
            "decision_consensus" => {
                let chosen = extract_field(&data, "chosen_option_id").unwrap_or("?");
                let method = extract_field(&data, "method").unwrap_or("unknown");
                let margin = extract_field(&data, "margin").unwrap_or("?");
                let summary = format!("[CONSENSUS] {} via {} (margin: {})", chosen, method, margin);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "decision_consensus".to_string(),
                    summary: summary.clone(),
                });
                update_council_deliberation(&summary);
                log::info!("MASC council: {}", summary);
            }
            "decision_phase" => {
                let phase = extract_field(&data, "phase").unwrap_or("unknown");
                let summary = format!("[PHASE] {}", phase);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "decision_phase".to_string(),
                    summary: summary.clone(),
                });
                update_council_deliberation(&summary);
                log::info!("MASC council: {}", summary);
            }

            // ─── Experiment (A/B Testing) ────────────────
            "experiment_created" => {
                let hypothesis = extract_field(&data, "hypothesis").unwrap_or("(no hypothesis)");
                let summary = format!("[NEW] {}", hypothesis);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "experiment_created".to_string(),
                    summary: summary.clone(),
                });
                update_experiment_dashboard(&summary);
                log::info!("MASC experiment: {}", summary);
            }
            "experiment_assignment" => {
                let subject_id = extract_field(&data, "subject_id").unwrap_or("?");
                let group = extract_field(&data, "group").unwrap_or("?");
                let summary = format!("[ASSIGN] {} -> {}", subject_id, group);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "experiment_assignment".to_string(),
                    summary: summary.clone(),
                });
                update_experiment_dashboard(&summary);
                log::info!("MASC experiment: {}", summary);
            }
            "experiment_observation" => {
                let metric_name = extract_field(&data, "metric_name").unwrap_or("?");
                let value = extract_field(&data, "value").unwrap_or("?");
                let summary = format!("[OBS] {}: {}", metric_name, value);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "experiment_observation".to_string(),
                    summary: summary.clone(),
                });
                update_experiment_dashboard(&summary);
                log::info!("MASC experiment: {}", summary);
            }
            "experiment_checkpoint" => {
                let elapsed_pct = extract_field(&data, "elapsed_pct").unwrap_or("?");
                let p_value = extract_field(&data, "p_value").unwrap_or("?");
                let summary = format!("[CHECK] {}% complete, p={}", elapsed_pct, p_value);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "experiment_checkpoint".to_string(),
                    summary: summary.clone(),
                });
                update_experiment_dashboard(&summary);
                log::info!("MASC experiment: {}", summary);
            }
            "experiment_concluded" => {
                let result = extract_field(&data, "result").unwrap_or("?");
                let effect_size = extract_field(&data, "effect_size").unwrap_or("?");
                let summary = format!("[DONE] {}, effect={}", result, effect_size);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "experiment_concluded".to_string(),
                    summary: summary.clone(),
                });
                update_experiment_dashboard(&summary);
                log::info!("MASC experiment: {}", summary);
            }

            // ─── TRPG Extensions ─────────────────────────
            "scene_transition" => {
                let from_scene = extract_field(&data, "from_scene").unwrap_or("?");
                let to_scene = extract_field(&data, "to_scene").unwrap_or("?");
                let summary = format!("[SCENE] {} -> {}", from_scene, to_scene);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "scene_transition".to_string(),
                    summary: summary.clone(),
                });
                update_monitor_events(&summary);
                log::info!("MASC trpg: {}", summary);
            }
            "quest_update" => {
                let title = extract_field(&data, "title").unwrap_or("?");
                let status = extract_field(&data, "status").unwrap_or("?");
                let summary = format!("[QUEST] {}: {}", title, status);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "quest_update".to_string(),
                    summary: summary.clone(),
                });
                update_monitor_events(&summary);
                log::info!("MASC trpg: {}", summary);
            }
            "world_event" => {
                let description = extract_field(&data, "description").unwrap_or("?");
                let severity = extract_field(&data, "severity").unwrap_or("info");
                let summary = format!("[WORLD] {} ({})", description, severity);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "world_event".to_string(),
                    summary: summary.clone(),
                });
                update_monitor_events(&summary);
                log::info!("MASC trpg: {}", summary);
            }

            other => {
                log::debug!("Unhandled MASC SSE event type: {}", other);
            }
        }
    }
}

// ─── DOM Update Helpers ──────────────────────
//
// All DOM access is gated on wasm32. On native, these are no-ops.

/// Update the Monitor panel "Agent Status" card.
fn update_monitor_agents(_count: u32, _summary: &str) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        if let Ok(Some(el)) = doc.query_selector("#monitor-agent-list") {
            let text = format!("{} agent(s) online\n{}", _count, _summary);
            el.set_text_content(Some(&text));
        }
    }
}

/// Update the Monitor panel "Room Activity" event feed.
fn update_monitor_events(_summary: &str) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        if let Ok(Some(el)) = doc.query_selector("#monitor-events") {
            let current = el.text_content().unwrap_or_default();
            let updated = format!("{}\n{}", _summary, current);
            let lines: Vec<&str> = updated.lines().take(50).collect();
            el.set_text_content(Some(&lines.join("\n")));
        }
    }
}

/// Update the Monitor panel "Task Queue" card.
fn update_monitor_tasks(_count: u32, _summary: &str) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        if let Ok(Some(el)) = doc.query_selector("#monitor-task-list") {
            let text = format!("{} active task(s)\n{}", _count, _summary);
            el.set_text_content(Some(&text));
        }
    }
}

/// Update the Social panel feed.
///
/// Instead of overwriting `#social-feed` with `set_text_content` (which conflicts
/// with `social_board::render_posts_to_dom` using `set_inner_html` on the same
/// element), SSE events are prepended as individual notification divs. This lets
/// board posts and SSE notifications coexist in the DOM.
fn update_social_feed(_summary: &str) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        if let Ok(Some(el)) = doc.query_selector("#social-feed") {
            if let Ok(div) = doc.create_element("div") {
                div.set_class_name("social-sse-notification");
                div.set_text_content(Some(_summary));
                el.insert_before(&div, el.first_child().as_ref()).ok();
                // Trim to 100 child nodes max
                while el.child_element_count() > 100 {
                    if let Some(last) = el.last_element_child() {
                        el.remove_child(&last).ok();
                    } else {
                        break;
                    }
                }
            }
        }
    }
}

/// Update the Council panel deliberation feed.
fn update_council_deliberation(_summary: &str) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        if let Ok(Some(el)) = doc.query_selector("#council-deliberation") {
            let current = el.text_content().unwrap_or_default();
            let updated = format!("{}\n{}", _summary, current);
            let lines: Vec<&str> = updated.lines().take(50).collect();
            el.set_text_content(Some(&lines.join("\n")));
        }
    }
}

/// Update the Experiment panel dashboard feed.
fn update_experiment_dashboard(_summary: &str) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        if let Ok(Some(el)) = doc.query_selector("#experiment-dashboard") {
            let current = el.text_content().unwrap_or_default();
            let updated = format!("{}\n{}", _summary, current);
            let lines: Vec<&str> = updated.lines().take(50).collect();
            el.set_text_content(Some(&lines.join("\n")));
        }
    }
}
