#![allow(dead_code)] // Infrastructure config — many items used only in wasm32 builds.

use crate::mode::ViewerMode;

// ─── Configuration ──────────────────────────

// With Trunk Proxy configured in Trunk.toml, we can use relative paths
// for both debug and release builds.
// This avoids CORS issues and hardcoded ports in the binary.
pub const MASC_MCP_URL: &str = "";

pub const DEFAULT_ROOM_ID: &str = "default";

// ─── Room ID Management ─────────────────────

/// Get current room ID from DOM attribute (set by dashboard/lobby) or URL param.
pub fn current_room_id() -> String {
    #[cfg(target_arch = "wasm32")]
    {
        // 1. Prefer runtime room bound to dashboard state.
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(el) = doc.get_element_by_id("dashboard") {
                if let Some(room) = el.get_attribute("data-room-id") {
                    if let Some(room) = sanitize_room_id(&room) {
                        return room;
                    }
                }
            }
        }

        // 2. Fallback to URL param ?room=...
        if let Some(win) = web_sys::window() {
            if let Ok(search) = win.location().search() {
                if let Some(room) = parse_query_param(&search, "room") {
                    return sanitize_room_id(&room).unwrap_or_else(|| DEFAULT_ROOM_ID.to_string());
                }
            }
        }
    }

    DEFAULT_ROOM_ID.to_string()
}

/// Set current room ID (persisted via URL or just runtime state).
/// In this viewer, we primarily use the dashboard data attribute.
#[allow(unused_variables)]
pub fn set_current_room_id(room_id: &str) {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(el) = doc.get_element_by_id("dashboard") {
                let _ = el.set_attribute("data-room-id", room_id);
            }
        }

        // Also update URL without reload?
        if let Some(win) = web_sys::window() {
            if let Ok(history) = win.history() {
                let mode_param = win
                    .location()
                    .search()
                    .ok()
                    .and_then(|search| parse_query_param(&search, "mode"))
                    .filter(|mode| !mode.trim().is_empty() && mode != "lobby");
                let url = match mode_param {
                    Some(mode) => format!("?mode={}&room={}", mode, room_id),
                    None => format!("?room={}", room_id),
                };
                let _ =
                    history.replace_state_with_url(&wasm_bindgen::JsValue::NULL, "", Some(&url));
            }
        }
    }
}

pub fn current_room_revision() -> u32 {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(el) = doc.get_element_by_id("dashboard") {
                if let Some(rev_str) = el.get_attribute("data-room-rev") {
                    if let Ok(rev) = rev_str.parse::<u32>() {
                        return rev;
                    }
                }
            }
        }
    }
    0
}

pub fn sanitize_room_id(raw: &str) -> Option<String> {
    let s = raw.trim();
    if s.is_empty() || s.len() > 64 {
        return None;
    }
    if s.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        Some(s.to_string())
    } else {
        None
    }
}

#[cfg(target_arch = "wasm32")]
fn parse_query_param(search: &str, key: &str) -> Option<String> {
    let search = search.trim_start_matches('?');
    for pair in search.split('&') {
        let mut parts = pair.splitn(2, '=');
        if let Some(k) = parts.next() {
            if k == key {
                return parts.next().map(|v| v.to_string());
            }
        }
    }
    None
}

// ─── Endpoints ──────────────────────────────

pub fn trpg_uses_polling() -> bool {
    // MASC exposes both poll JSON and SSE endpoints.
    // Current viewer runtime uses polling reliably because stream responses are
    // JSON payloads and SSE is optional when available.
    true
}

pub fn trpg_state_url() -> String {
    format!(
        "{}/api/v1/trpg/state?room_id={}",
        MASC_MCP_URL,
        current_room_id()
    )
}

/// Legacy JSON poll endpoint.
pub fn trpg_stream_poll_url(after_seq: i64) -> String {
    format!(
        "{}/api/v1/trpg/stream?room_id={}&after_seq={}",
        MASC_MCP_URL,
        current_room_id(),
        after_seq
    )
}

pub fn sse_endpoint(mode: &ViewerMode) -> Option<String> {
    match mode {
        ViewerMode::Trpg => Some(format!(
            "{}/api/v1/trpg/stream/sse?room_id={}",
            MASC_MCP_URL,
            current_room_id()
        )),
        ViewerMode::Monitor => Some(format!("{}/sse?room=monitor", MASC_MCP_URL)),
        ViewerMode::Experiment => Some(format!("{}/sse?room=experiment", MASC_MCP_URL)),
        ViewerMode::Council => Some(format!("{}/sse?room=council", MASC_MCP_URL)),
        ViewerMode::Social => Some(format!("{}/sse?room=social", MASC_MCP_URL)),
        ViewerMode::Lobby => None,
    }
}

/// Resolve SSE endpoint by mode name string (for use from async contexts
/// that don't have access to Bevy State<ViewerMode>).
pub fn sse_endpoint_by_name(mode_name: &str) -> Option<String> {
    match mode_name {
        "Trpg" => Some(format!(
            "{}/api/v1/trpg/stream/sse?room_id={}",
            MASC_MCP_URL,
            current_room_id()
        )),
        "Monitor" => Some(format!("{}/sse?room=monitor", MASC_MCP_URL)),
        "Experiment" => Some(format!("{}/sse?room=experiment", MASC_MCP_URL)),
        "Council" => Some(format!("{}/sse?room=council", MASC_MCP_URL)),
        "Social" => Some(format!("{}/sse?room=social", MASC_MCP_URL)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sse_endpoint_routes_masc_modes_to_legacy_sse() {
        assert_eq!(
            sse_endpoint(&ViewerMode::Monitor).as_deref(),
            Some("/sse?room=monitor")
        );
        assert_eq!(
            sse_endpoint(&ViewerMode::Experiment).as_deref(),
            Some("/sse?room=experiment")
        );
        assert_eq!(
            sse_endpoint(&ViewerMode::Council).as_deref(),
            Some("/sse?room=council")
        );
        assert_eq!(
            sse_endpoint(&ViewerMode::Social).as_deref(),
            Some("/sse?room=social")
        );
    }

    #[test]
    fn sse_endpoint_by_name_matches_stateful_variant() {
        assert_eq!(
            sse_endpoint_by_name("Monitor").as_deref(),
            Some("/sse?room=monitor")
        );
        assert_eq!(
            sse_endpoint_by_name("Experiment").as_deref(),
            Some("/sse?room=experiment")
        );
        assert_eq!(
            sse_endpoint_by_name("Council").as_deref(),
            Some("/sse?room=council")
        );
        assert_eq!(
            sse_endpoint_by_name("Social").as_deref(),
            Some("/sse?room=social")
        );
    }
}
