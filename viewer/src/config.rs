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

/// Get current room ID from DOM attribute (set by dashboard/lobby) or URL param.
pub fn current_room_id() -> String {
    #[cfg(target_arch = "wasm32")]
    {
        // 1. Try URL param ?room=...
        if let Some(win) = web_sys::window() {
            if let Ok(search) = win.location().search() {
                if let Some(room) = parse_query_param(&search, "room") {
                    return sanitize_room_id(&room).unwrap_or_else(|| DEFAULT_ROOM_ID.to_string());
                }
            }
        }

        // 2. Try dashboard attribute
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(el) = doc.get_element_by_id("dashboard") {
                if let Some(room) = el.get_attribute("data-room-id") {
                    if !room.is_empty() {
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
    // MASC API supports SSE, so polling is fallback or for legacy engine.
    // If using MASC API, we use SSE.
    // If using Legacy Engine, we might need polling if SSE not exposed?
    // Actually MASC API exposes /stream/sse.
    false
}

pub fn trpg_state_url() -> String {
    format!("{}/api/v1/trpg/state/{}", MASC_MCP_URL, current_room_id())
}

pub fn trpg_stream_poll_url(after_seq: i64) -> String {
    format!("{}/api/v1/trpg/stream/poll/{}?after={}", MASC_MCP_URL, current_room_id(), after_seq)
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
