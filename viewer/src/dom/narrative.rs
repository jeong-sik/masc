use bevy::prelude::*;
use wasm_bindgen::closure::Closure;
use wasm_bindgen::JsCast;

use crate::game::events::NarrativeReceived;
use crate::game::state::{TurnProgressState, WorkspaceState};

use super::dm_voice;
use super::escape::{sanitize_text, scroll_to_bottom, trim_log};
use super::session_history::sync_history_focus_from_dashboard;

fn truncate_before_meta_markers(raw: &str) -> &str {
    const MARKERS: [&str; 2] = ["visible_state_json:", "반드시 한국어로 응답하세요"];
    let mut cut = raw.len();
    for marker in MARKERS {
        if let Some(idx) = raw.find(marker) {
            cut = cut.min(idx);
        }
    }
    &raw[..cut]
}

fn strip_fenced_code_blocks(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut in_fence = false;
    for line in raw.lines() {
        if line.trim_start().starts_with("```") {
            in_fence = !in_fence;
            continue;
        }
        if !in_fence {
            out.push_str(line);
            out.push('\n');
        }
    }
    out
}

fn is_meta_line(line: &str) -> bool {
    let lower = line.trim().to_ascii_lowercase();
    lower.starts_with("skill:")
        || lower.starts_with("skill_reason:")
        || lower.contains("structured_action")
}

fn is_prompt_recall_artifact(raw: &str) -> bool {
    let lower = raw.to_ascii_lowercase();
    let has_visible_state = lower.contains("visible_state_json:");
    let has_state_dump = lower.contains("\"narration_log\"")
        || lower.contains("\"dice_log\"")
        || lower.contains("\"party\"");
    let has_prompt_directive =
        lower.contains("trpg 실행 요청입니다") || lower.contains("반드시 한국어로 응답하세요");
    let has_reply_blob = lower.contains("\"reply\":") && lower.contains("skill:");

    (has_visible_state && (has_state_dump || has_prompt_directive)) || has_reply_blob
}

fn normalize_narrative_text(raw: &str) -> String {
    if is_prompt_recall_artifact(raw) {
        return String::new();
    }

    let truncated = truncate_before_meta_markers(raw);
    let no_code = strip_fenced_code_blocks(truncated);

    let mut lines: Vec<String> = Vec::new();
    let mut pending_blank = false;
    for line in no_code.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            if !lines.is_empty() {
                pending_blank = true;
            }
            continue;
        }
        if is_meta_line(trimmed) {
            continue;
        }
        if pending_blank {
            lines.push(String::new());
            pending_blank = false;
        }
        lines.push(trimmed.to_string());
    }

    lines.join("\n").trim().to_string()
}

fn normalize_phase_suffix(phase: &str) -> String {
    let mut out = String::with_capacity(phase.len());
    for ch in phase.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
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

fn is_debug_narrative(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("[timeout]") || lower.contains("[unavailable]")
}

fn debug_mode_enabled(document: &web_sys::Document) -> bool {
    document
        .get_element_by_id("dashboard")
        .and_then(|el| el.get_attribute("data-debug"))
        .map(|mode| mode != "off")
        .unwrap_or(true)
}

fn apply_debug_visibility(el: &web_sys::Element, debug_enabled: bool, is_debug_entry: bool) {
    let display = if !debug_enabled && is_debug_entry {
        "none"
    } else {
        "block"
    };
    if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
        let _ = html_el.style().set_property("display", display);
    }
}

fn toggle_selected_class(el: &web_sys::Element) {
    let current = el.class_name();
    let has_selected = current.split_whitespace().any(|cls| cls == "selected");
    let next = if has_selected {
        current
            .split_whitespace()
            .filter(|cls| *cls != "selected")
            .collect::<Vec<_>>()
            .join(" ")
    } else if current.trim().is_empty() {
        "selected".to_string()
    } else {
        format!("{} selected", current.trim())
    };
    el.set_class_name(next.trim());
}

fn bump_dedup_narrative(document: &web_sys::Document, sample: &str) {
    let Some(dashboard) = document.get_element_by_id("dashboard") else {
        return;
    };
    let next = dashboard
        .get_attribute("data-dedup-narrative")
        .and_then(|raw| raw.parse::<u64>().ok())
        .unwrap_or(0)
        .saturating_add(1);
    let _ = dashboard.set_attribute("data-dedup-narrative", &next.to_string());

    let mut lines = dashboard
        .get_attribute("data-dedup-samples-narrative")
        .unwrap_or_default()
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    let trimmed = sample.trim();
    if !trimmed.is_empty() {
        lines.push(trimmed.chars().take(160).collect());
    }
    if lines.len() > 24 {
        let drain = lines.len() - 24;
        lines.drain(0..drain);
    }
    let _ = dashboard.set_attribute("data-dedup-samples-narrative", &lines.join("\n"));
}

fn is_duplicate_narrative_entry(log_el: &web_sys::Element, dedup_key: &str) -> bool {
    let mut scanned = 0_u32;
    let mut cursor = log_el.last_element_child();
    while scanned < 40 {
        let Some(el) = cursor else {
            break;
        };
        if el
            .get_attribute("data-dedup-key")
            .map(|value| value == dedup_key)
            .unwrap_or(false)
        {
            return true;
        }
        cursor = el.previous_element_sibling();
        scanned += 1;
    }
    false
}

/// Appends narrative entries to the #narrative-log DOM element.
pub fn update_narrative_dom(
    mut events: MessageReader<NarrativeReceived>,
    workspace_state: Res<WorkspaceState>,
    progress: Res<TurnProgressState>,
) {
    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(log_el) = document.get_element_by_id("narrative-log") else {
        return;
    };
    let debug_enabled = debug_mode_enabled(&document);

    // P5: Manage thinking placeholder divs based on TurnProgressState.
    // Inject a spinner for each actor currently in "thinking" state,
    // and remove placeholders for actors that have left that state.
    {
        // Collect currently-thinking actor IDs.
        let thinking_ids: Vec<&String> = progress
            .actor_states
            .iter()
            .filter(|(_, state)| state.as_str() == "thinking")
            .map(|(id, _)| id)
            .collect();

        // Remove stale placeholders (actors no longer thinking).
        let mut to_remove = Vec::new();
        let children = log_el.children();
        for i in 0..children.length() {
            if let Some(child) = children.item(i) {
                if let Some(id) = child.get_attribute("data-thinking-actor") {
                    if !thinking_ids.iter().any(|tid| tid.as_str() == id) {
                        to_remove.push(child);
                    }
                }
            }
        }
        for el in to_remove {
            let _ = log_el.remove_child(&el);
        }

        // Create placeholders for newly-thinking actors (if not already present).
        for actor_id in &thinking_ids {
            let placeholder_id = format!("thinking-{}", actor_id);
            if document.get_element_by_id(&placeholder_id).is_none() {
                if let Ok(div) = document.create_element("div") {
                    div.set_class_name("narrative-entry thinking-placeholder");
                    let _ = div.set_attribute("id", &placeholder_id);
                    let _ = div.set_attribute("data-thinking-actor", actor_id);
                    let label = sanitize_text(actor_id);
                    div.set_inner_html(&format!(
                        "<span class=\"thinking-spinner\"></span> <span class=\"thinking-label\">{} thinking…</span>",
                        label
                    ));
                    let _ = log_el.append_child(&div);
                    scroll_to_bottom(&log_el);
                }
            }
        }
    }

    for NarrativeReceived(payload) in events.read() {
        let Ok(entry) = document.create_element("div") else {
            continue;
        };
        let phase_text = sanitize_text(&payload.phase);
        let phase_suffix = normalize_phase_suffix(&phase_text);
        entry.set_class_name(&format!("narrative-entry phase-{}", phase_suffix));
        let _ = entry.set_attribute("role", "button");
        let _ = entry.set_attribute("tabindex", "0");
        let _ = entry.set_attribute("title", "클릭하면 이 내러티브를 강조합니다.");
        let clean_text = sanitize_text(&normalize_narrative_text(&payload.text));
        if clean_text.trim().is_empty() {
            continue;
        }
        let speaker_raw = payload
            .speaker
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("system");

        // P5: Remove thinking placeholder for this speaker when their narrative arrives.
        if speaker_raw != "system" {
            let placeholder_id = format!("thinking-{}", speaker_raw);
            if let Some(placeholder) = document.get_element_by_id(&placeholder_id) {
                let _ = log_el.remove_child(&placeholder);
            }
        }

        let dedup_key = format!(
            "{}|{}|{}|{}",
            payload.turn,
            phase_text.trim().to_ascii_lowercase(),
            speaker_raw.to_ascii_lowercase(),
            clean_text.trim()
        );
        if is_duplicate_narrative_entry(&log_el, &dedup_key) {
            bump_dedup_narrative(
                &document,
                &format!(
                    "t{} | {} | {} | {}",
                    payload.turn,
                    phase_text.trim(),
                    speaker_raw,
                    clean_text.trim()
                ),
            );
            continue;
        }
        let _ = entry.set_attribute("data-dedup-key", &dedup_key);
        if payload.turn > 0 {
            let _ = entry.set_attribute("data-turn", &payload.turn.to_string());
        }
        let is_debug_entry = is_debug_narrative(&clean_text);
        if is_debug_entry {
            let _ = entry.set_attribute("data-debug-entry", "1");
        }

        let speaker = payload
            .speaker
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(sanitize_text);

        if let Ok(meta_el) = document.create_element("div") {
            meta_el.set_class_name("narrative-meta");
            let meta_text = if let Some(speaker) = speaker.as_deref() {
                format!("{} · {}", phase_text, speaker)
            } else {
                phase_text.clone()
            };
            meta_el.set_text_content(Some(&meta_text));
            let _ = entry.append_child(&meta_el);
        }

        // Never insert streamed text via innerHTML.
        if let Some(speaker) = speaker.as_deref() {
            if let Ok(speaker_el) = document.create_element("span") {
                speaker_el.set_class_name("narrative-speaker");
                speaker_el.set_text_content(Some(speaker));
                let _ = entry.append_child(&speaker_el);
            }
        }
        if let Ok(text_el) = document.create_element("span") {
            text_el.set_class_name("narrative-text");
            let text = if speaker.is_some() {
                format!(" {}", clean_text)
            } else {
                clean_text.clone()
            };
            text_el.set_text_content(Some(&text));
            let _ = entry.append_child(&text_el);
        }

        let clickable_entry = entry.clone();
        let click_cb = Closure::wrap(Box::new(move || {
            toggle_selected_class(&clickable_entry);
            let Some(document) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            let Some(dashboard) = document.get_element_by_id("dashboard") else {
                return;
            };
            if let Some(workspace_id) = clickable_entry.get_attribute("data-workspace-id") {
                if !workspace_id.trim().is_empty() {
                    let _ = dashboard.set_attribute("data-focus-workspace", workspace_id.trim());
                }
            }
            if let Some(turn) = clickable_entry.get_attribute("data-turn") {
                if !turn.trim().is_empty() {
                    let _ = dashboard.set_attribute("data-focus-turn", turn.trim());
                }
            }
            sync_history_focus_from_dashboard(&document);
        }) as Box<dyn FnMut()>);
        let _ = entry.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", click_cb.as_ref().unchecked_ref())
        });
        click_cb.forget();

        let _ = log_el.append_child(&entry);
        apply_debug_visibility(&entry, debug_enabled, is_debug_entry);
        scroll_to_bottom(&log_el);
        trim_log(&log_el, 200);
        if !is_debug_entry {
            dm_voice::maybe_play_dm_voice(payload, &clean_text, &workspace_state, &progress);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{normalize_narrative_text, normalize_phase_suffix};

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

    #[test]
    fn normalize_narrative_text_removes_meta_sections() {
        let raw = r#"SKILL: masc-keeper-autonomy
SKILL_REASON: test

비가 내리는 강가에 적들이 접근한다.

```json
{"structured_action":{"action_type":"narrative_setup"}}
```
"#;

        assert_eq!(
            normalize_narrative_text(raw),
            "비가 내리는 강가에 적들이 접근한다."
        );
    }

    #[test]
    fn normalize_narrative_text_truncates_prompt_echo_suffix() {
        let raw = r#"장면은 유지된다.
visible_state_json:
{"turn":8}
"#;
        assert_eq!(normalize_narrative_text(raw), "장면은 유지된다.");
    }

    #[test]
    fn normalize_narrative_text_drops_prompt_recall_blob() {
        let raw = r#""reply": "SKILL: masc-heartbeat ... "
visible_state_json:
{
  "narration_log": [],
  "dice_log": []
}
반드시 한국어로 응답하세요.
"#;
        assert_eq!(normalize_narrative_text(raw), "");
    }
}
