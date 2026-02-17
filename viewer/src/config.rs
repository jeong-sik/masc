use crate::mode::ViewerMode;

// ─── Configuration ──────────────────────────

#[cfg(debug_assertions)]
pub const MASC_MCP_URL: &str = "http://localhost:8935"; // Updated to match active server port

#[cfg(not(debug_assertions))]
pub const MASC_MCP_URL: &str = ""; // Relative path in production

pub const DEFAULT_ROOM_ID: &str = "default";

/// Legacy TRPG Engine URL (for direct mode)
#[cfg(debug_assertions)]
pub const TRPG_ENGINE_URL: &str = "http://localhost:8000";

#[cfg(not(debug_assertions))]
pub const TRPG_ENGINE_URL: &str = "";

// ─── Backend Mode ───────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrpgBackendMode {
    MascApi,    // Uses /api/v1/trpg endpoints (default)
    LegacyEngine // Uses direct engine endpoints (if needed)
}

pub const DEFAULT_TRPG_BACKEND: TrpgBackendMode = TrpgBackendMode::MascApi;

// ─── Room ID Management ─────────────────────

/// Read `?room=...` from URL and return a sanitized room id.
pub fn room_id_from_url() -> Option<String> {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(win) = web_sys::window() {
            if let Ok(search) = win.location().search() {
                return parse_query_param(&search, "room").and_then(|room| sanitize_room_id(&room));
            }
        }
    }

    None
}

/// Get current room ID from DOM attribute (set by dashboard/lobby) or URL param.
pub fn current_room_id() -> String {
    if let Some(room) = room_id_from_url() {
        return room;
    }

    #[cfg(target_arch = "wasm32")]
    {
        // 2. Try dashboard attribute
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(el) = doc.get_element_by_id("dashboard") {
                if let Some(room) = el.get_attribute("data-room-id") {
                    if let Some(room) = sanitize_room_id(&room) {
                        return room;
                    }
                }
            }
        }
    }
    
    DEFAULT_ROOM_ID.to_string()
}

/// Set current room ID (persisted via URL or just runtime state).
/// In this viewer, we primarily use the dashboard data attribute.
pub fn set_current_room_id(room_id: &str) {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(el) = doc.get_element_by_id("dashboard") {
                let _ = el.set_attribute("data-room-id", room_id);
                let next_rev = el
                    .get_attribute("data-room-rev")
                    .and_then(|s| s.parse::<u64>().ok())
                    .unwrap_or(0)
                    .saturating_add(1);
                let _ = el.set_attribute("data-room-rev", &next_rev.to_string());
            }
        }
        
        // Also update URL without reload?
        if let Some(win) = web_sys::window() {
            if let Ok(history) = win.history() {
                let url = format!("?room={}", room_id);
                let _ = history.push_state_with_url(&wasm_bindgen::JsValue::NULL, "", Some(&url));
            }
        }
    }
}

/// Monotonic room revision that increments whenever the room is explicitly set.
/// Used to detect "same room re-apply" operations.
pub fn current_room_revision() -> u64 {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(el) = doc.get_element_by_id("dashboard") {
                return el
                    .get_attribute("data-room-rev")
                    .and_then(|s| s.parse::<u64>().ok())
                    .unwrap_or(0);
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
    if s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
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

// ─── Polling Configuration ──────────────────

pub const TRPG_POLL_INTERVAL_MS: u64 = 500; // 500ms polling interval for stream/poll endpoint

pub fn trpg_uses_polling() -> bool {
    true
}

pub fn trpg_state_url() -> String {
    format!(
        "{}/api/v1/trpg/state?room_id={}",
        MASC_MCP_URL,
        current_room_id()
    )
}

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
        ViewerMode::Trpg => Some(format!("{}/api/v1/trpg/stream/sse/{}", MASC_MCP_URL, current_room_id())),
        ViewerMode::Monitor => Some(format!("{}/api/v1/monitor/stream", MASC_MCP_URL)),
        ViewerMode::Experiment => Some(format!("{}/api/v1/experiment/stream", MASC_MCP_URL)),
        ViewerMode::Council => Some(format!("{}/api/v1/council/stream", MASC_MCP_URL)),
        ViewerMode::Social => Some(format!("{}/api/v1/social/stream", MASC_MCP_URL)),
        ViewerMode::Lobby => None,
    }
}

/// Helper to get full room URL for external links (if needed)
pub fn trpg_room_url(path: &str) -> String {
    format!("{}/rooms/{}/{}", MASC_MCP_URL, current_room_id(), path.trim_start_matches('/'))
}

// ─── Actor ID Management ─────────────────────

/// Get current actor ID from dashboard attribute (selected player in lobby).
/// This serves as a fallback when TurnProgressState doesn't have an active actor.
pub fn current_actor_id() -> Option<String> {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            // 1. Try dashboard attribute (set by lobby/character selection)
            if let Some(el) = doc.get_element_by_id("dashboard") {
                if let Some(actor) = el.get_attribute("data-current-actor") {
                    let actor = actor.trim().to_string();
                    if !actor.is_empty() {
                        return Some(actor);
                    }
                }
            }
        }
    }

    None
}
