#![allow(dead_code)] // Infrastructure config — many items used only in wasm32 builds.

use crate::mode::ViewerMode;

// ─── Configuration ──────────────────────────

// Optional compile-time upstream override.
// Keep empty by default so local dev still uses relative paths + Trunk proxy.
#[cfg(target_arch = "wasm32")]
const COMPILE_TIME_MASC_MCP_URL: &str = match option_env!("MASC_MCP_URL") {
    Some(v) => v,
    None => "",
};
#[cfg(not(target_arch = "wasm32"))]
const COMPILE_TIME_MASC_MCP_URL: &str = "";

/// Backward-compatible static base URL for legacy call sites.
pub const MASC_MCP_URL: &str = COMPILE_TIME_MASC_MCP_URL;

pub const DEFAULT_ROOM_ID: &str = "default";

fn normalize_base_url(base: &str) -> String {
    base.trim().trim_end_matches('/').to_string()
}

fn compose_masc_url(base: &str, path: &str) -> String {
    let normalized_base = normalize_base_url(base);
    let normalized_path = path.trim_start_matches('/');
    if normalized_base.is_empty() {
        format!("/{}", normalized_path)
    } else {
        format!("{}/{}", normalized_base, normalized_path)
    }
}

#[cfg(target_arch = "wasm32")]
fn runtime_base_url_override() -> Option<String> {
    let win = web_sys::window()?;

    // 1) Explicit global override:
    //    window.__MASC_MCP_URL = "https://your-masc.up.railway.app"
    if let Ok(value) = js_sys::Reflect::get(
        win.as_ref(),
        &wasm_bindgen::JsValue::from_str("__MASC_MCP_URL"),
    ) {
        if let Some(raw) = value.as_string() {
            let normalized = normalize_base_url(&raw);
            if !normalized.is_empty() {
                return Some(normalized);
            }
        }
    }

    // 2) URL query override:
    //    ?masc_mcp_url=https://your-masc.up.railway.app
    if let Ok(search) = win.location().search() {
        if let Some(raw) = parse_query_param(&search, "masc_mcp_url") {
            let normalized = normalize_base_url(&raw);
            if !normalized.is_empty() {
                if let Ok(Some(storage)) = win.local_storage() {
                    let _ = storage.set_item("masc_mcp_url", &normalized);
                }
                return Some(normalized);
            }
        }
    }

    // 3) localStorage fallback:
    //    localStorage.setItem("masc_mcp_url", "https://your-masc.up.railway.app")
    if let Ok(Some(storage)) = win.local_storage() {
        if let Ok(Some(raw)) = storage.get_item("masc_mcp_url") {
            let normalized = normalize_base_url(&raw);
            if !normalized.is_empty() {
                return Some(normalized);
            }
        }
    }

    // 4) Meta tag fallback:
    //    <meta name="masc-mcp-url" content="https://your-masc.up.railway.app">
    if let Some(doc) = win.document() {
        if let Ok(Some(meta)) = doc.query_selector("meta[name='masc-mcp-url']") {
            if let Some(raw) = meta.get_attribute("content") {
                let normalized = normalize_base_url(&raw);
                if !normalized.is_empty() {
                    return Some(normalized);
                }
            }
        }
    }

    None
}

pub fn masc_mcp_base_url() -> String {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(runtime) = runtime_base_url_override() {
            return runtime;
        }
    }
    normalize_base_url(COMPILE_TIME_MASC_MCP_URL)
}

pub fn build_masc_url(path: &str) -> String {
    compose_masc_url(&masc_mcp_base_url(), path)
}

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
    build_masc_url(&format!("api/v1/trpg/state?room_id={}", current_room_id()))
}

/// Legacy JSON poll endpoint.
pub fn trpg_stream_poll_url(after_seq: i64) -> String {
    build_masc_url(&format!(
        "api/v1/trpg/stream?room_id={}&after_seq={}",
        current_room_id(),
        after_seq
    ))
}

pub fn sse_endpoint(mode: &ViewerMode) -> Option<String> {
    match mode {
        ViewerMode::Trpg => Some(build_masc_url(&format!(
            "api/v1/trpg/stream/sse?room_id={}",
            current_room_id()
        ))),
        ViewerMode::Monitor => Some(build_masc_url("sse?room=monitor")),
        ViewerMode::Experiment => Some(build_masc_url("sse?room=experiment")),
        ViewerMode::Council => Some(build_masc_url("sse?room=council")),
        ViewerMode::Social => Some(build_masc_url("sse?room=social")),
        ViewerMode::Lobby => None,
    }
}

/// Resolve SSE endpoint by mode name string (for use from async contexts
/// that don't have access to Bevy State<ViewerMode>).
pub fn sse_endpoint_by_name(mode_name: &str) -> Option<String> {
    match mode_name {
        "Trpg" => Some(build_masc_url(&format!(
            "api/v1/trpg/stream/sse?room_id={}",
            current_room_id()
        ))),
        "Monitor" => Some(build_masc_url("sse?room=monitor")),
        "Experiment" => Some(build_masc_url("sse?room=experiment")),
        "Council" => Some(build_masc_url("sse?room=council")),
        "Social" => Some(build_masc_url("sse?room=social")),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compose_masc_url_supports_relative_mode() {
        assert_eq!(
            compose_masc_url("", "api/v1/trpg/state"),
            "/api/v1/trpg/state"
        );
        assert_eq!(
            compose_masc_url("", "/sse?room=monitor"),
            "/sse?room=monitor"
        );
    }

    #[test]
    fn compose_masc_url_supports_absolute_upstream() {
        assert_eq!(
            compose_masc_url(
                "https://masc-mcp-production.up.railway.app",
                "api/v1/trpg/state?room_id=default"
            ),
            "https://masc-mcp-production.up.railway.app/api/v1/trpg/state?room_id=default"
        );
        assert_eq!(
            compose_masc_url(
                "https://masc-mcp-production.up.railway.app/",
                "/sse?room=monitor"
            ),
            "https://masc-mcp-production.up.railway.app/sse?room=monitor"
        );
    }

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
