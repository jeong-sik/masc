use bevy::prelude::*;
use serde_json::Value;

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

fn normalize_message_event_type(raw: &str) -> &str {
    match raw {
        "masc/broadcast" => "broadcast",
        "masc/heartbeat" => "heartbeat",
        "masc/agent_joined" => "agent_joined",
        "masc/agent_left" => "agent_left",
        "masc/task_update" => "task_update",
        _ => raw,
    }
}

/// Streamable HTTP often delivers typed events as `event: message` envelopes.
/// Extract inner `params.type` + `params.data` so downstream routing works.
fn unwrap_message_event(data: &str) -> Option<(String, String)> {
    let parsed: Value = serde_json::from_str(data).ok()?;
    let params = parsed.get("params")?;
    let raw_type = params.get("type")?.as_str()?;
    let event_type = normalize_message_event_type(raw_type).to_string();

    let payload = params.get("data").cloned().unwrap_or(Value::Null);
    let payload_json = if payload.is_null() {
        "{}".to_string()
    } else {
        payload.to_string()
    };

    Some((event_type, payload_json))
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

    for (raw_event_type, raw_data) in msgs.drain(..) {
        let (event_type, data) = if raw_event_type == "message" {
            unwrap_message_event(&raw_data).unwrap_or((raw_event_type, raw_data))
        } else {
            (raw_event_type, raw_data)
        };

        match event_type.as_str() {
            "broadcast" => {
                let message = extract_field(&data, "message")
                    .or_else(|| extract_field(&data, "content"))
                    .unwrap_or("(no message)");
                let agent = extract_field(&data, "agent_name")
                    .or_else(|| extract_field(&data, "from"))
                    .unwrap_or("unknown");
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
                let agent = extract_field(&data, "agent_name")
                    .or_else(|| extract_field(&data, "agent"))
                    .unwrap_or("unknown");
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
                let agent = extract_field(&data, "agent_name")
                    .or_else(|| extract_field(&data, "agent"))
                    .unwrap_or("unknown");
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unwrap_message_event_extracts_inner_type_and_payload() {
        let raw = r#"{"jsonrpc":"2.0","method":"masc/event","params":{"type":"experiment_created","agent":"tester","data":{"id":"exp-1","hypothesis":"smoke"}}}"#;
        let (event_type, payload) = unwrap_message_event(raw).expect("envelope should parse");

        assert_eq!(event_type, "experiment_created");
        assert_eq!(extract_field(&payload, "id"), Some("exp-1"));
        assert_eq!(extract_field(&payload, "hypothesis"), Some("smoke"));
    }

    #[test]
    fn unwrap_message_event_normalizes_masc_broadcast() {
        let raw = r#"{"jsonrpc":"2.0","method":"masc/event","params":{"type":"masc/broadcast","agent":"tester","data":{"from":"alice","content":"hello"}}}"#;
        let (event_type, payload) = unwrap_message_event(raw).expect("envelope should parse");

        assert_eq!(event_type, "broadcast");
        assert_eq!(extract_field(&payload, "from"), Some("alice"));
        assert_eq!(extract_field(&payload, "content"), Some("hello"));
    }
}
