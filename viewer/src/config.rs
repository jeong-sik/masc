//! Connection configuration for each viewer mode.
//!
//! Each `ViewerMode` connects to a different backend endpoint:
//! - TRPG: TRPG Engine (FastAPI, event sourcing)
//! - Monitor/Experiment/Council/Social: MASC MCP server (OCaml, SSE)
//!
//! The Lobby mode has no SSE connection — it's a pure UI state.

use crate::mode::ViewerMode;

/// TRPG Engine server (Codex-built, FastAPI + SQLite event store).
pub const TRPG_ENGINE_URL: &str = "http://localhost:8940";

/// MASC MCP server (OCaml + Eio, SSE + JSON-RPC).
#[allow(dead_code)]
pub const MASC_MCP_URL: &str = "http://localhost:8935";

/// Default TRPG room identifier.
pub const DEFAULT_ROOM_ID: &str = "default";

/// SSE endpoint for a given viewer mode.
/// Returns `None` for Lobby (no live data connection).
#[allow(dead_code)]
pub fn sse_endpoint(mode: &ViewerMode) -> Option<String> {
    match mode {
        ViewerMode::Lobby => None,
        ViewerMode::Trpg => Some(format!(
            "{}/rooms/{}/stream",
            TRPG_ENGINE_URL, DEFAULT_ROOM_ID
        )),
        ViewerMode::Experiment => Some(format!("{}/sse?room=experiment", MASC_MCP_URL)),
        ViewerMode::Monitor => Some(format!("{}/sse?room=monitor", MASC_MCP_URL)),
        ViewerMode::Council => Some(format!("{}/sse?room=council", MASC_MCP_URL)),
        ViewerMode::Social => Some(format!("{}/sse?room=social", MASC_MCP_URL)),
    }
}

/// HTTP base URL for initial state loading in a given mode.
#[allow(dead_code)]
pub fn http_base_url(mode: &ViewerMode) -> &'static str {
    match mode {
        ViewerMode::Trpg => TRPG_ENGINE_URL,
        _ => MASC_MCP_URL,
    }
}

/// TRPG-specific room URL helper (used by game state loader).
pub fn trpg_room_url(path: &str) -> String {
    format!("{}/rooms/{}{}", TRPG_ENGINE_URL, DEFAULT_ROOM_ID, path)
}
