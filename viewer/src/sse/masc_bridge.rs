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
#[derive(Resource)]
pub struct MascEventLog {
    pub entries: Vec<MascLogEntry>,
    pub agent_count: u32,
    pub task_count: u32,
}

impl Default for MascEventLog {
    fn default() -> Self {
        Self {
            entries: Vec::new(),
            agent_count: 0,
            task_count: 0,
        }
    }
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
                let message = extract_field(&data, "message")
                    .unwrap_or("(no message)");
                let agent = extract_field(&data, "agent_name")
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
                    .unwrap_or("unknown");
                event_log.agent_count = event_log.agent_count.saturating_add(1);

                let summary = format!("{} joined", agent);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "agent_joined".to_string(),
                    summary: summary.clone(),
                });

                update_monitor_agents(event_log.agent_count, &summary);

                log::info!("MASC agent joined: {} (total: {})", agent, event_log.agent_count);
            }
            "agent_left" => {
                let agent = extract_field(&data, "agent_name")
                    .unwrap_or("unknown");
                event_log.agent_count = event_log.agent_count.saturating_sub(1);

                let summary = format!("{} left", agent);
                event_log.entries.push(MascLogEntry {
                    timestamp: now,
                    event_type: "agent_left".to_string(),
                    summary: summary.clone(),
                });

                update_monitor_agents(event_log.agent_count, &summary);

                log::info!("MASC agent left: {} (total: {})", agent, event_log.agent_count);
            }
            "task_update" => {
                let task_id = extract_field(&data, "task_id")
                    .unwrap_or("?");
                let status = extract_field(&data, "status")
                    .unwrap_or("unknown");

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
        // Monitor panel > first monitor-card > placeholder-text
        if let Ok(Some(el)) = doc.query_selector(
            "#monitor-panel .monitor-card:nth-child(1) .placeholder-text",
        ) {
            let text = format!("{} agent(s) online\n{}", _count, _summary);
            el.set_text_content(Some(&text));
        }
    }
}

/// Update the Monitor panel "Room Activity" card.
fn update_monitor_events(_summary: &str) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        // Monitor panel > second monitor-card > placeholder-text
        if let Ok(Some(el)) = doc.query_selector(
            "#monitor-panel .monitor-card:nth-child(2) .placeholder-text",
        ) {
            el.set_text_content(Some(_summary));
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
        // Monitor panel > third monitor-card > placeholder-text
        if let Ok(Some(el)) = doc.query_selector(
            "#monitor-panel .monitor-card:nth-child(3) .placeholder-text",
        ) {
            let text = format!("{} active task(s)\n{}", _count, _summary);
            el.set_text_content(Some(&text));
        }
    }
}

/// Update the Social panel feed.
fn update_social_feed(_summary: &str) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        if let Ok(Some(el)) =
            doc.query_selector("#social-panel .social-feed .placeholder-text")
        {
            el.set_text_content(Some(_summary));
        }
    }
}
