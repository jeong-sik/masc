//! Connection configuration for each viewer mode.
//!
//! Each `ViewerMode` connects to a different backend endpoint:
//! - TRPG: MASC TRPG HTTP API (default) or legacy TRPG Engine SSE
//! - Monitor/Experiment/Council/Social: MASC MCP server (OCaml, SSE)
//!
//! The Lobby mode has no SSE connection — it's a pure UI state.

use crate::mode::ViewerMode;

/// Legacy TRPG Engine server (FastAPI + SQLite event store).
pub const TRPG_ENGINE_URL: &str = "http://localhost:8940";

/// MASC MCP server (OCaml + Eio, SSE + JSON-RPC).
pub const MASC_MCP_URL: &str = "http://localhost:8935";

/// Default TRPG room identifier.
pub const DEFAULT_ROOM_ID: &str = "default";

/// Poll interval for MASC TRPG stream JSON endpoint.
#[cfg(target_arch = "wasm32")]
pub const TRPG_POLL_INTERVAL_MS: i32 = 1000;

/// Backend mode for TRPG view.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrpgBackendMode {
    /// MASC `/api/v1/trpg/*` JSON API (default, protocol-unified path).
    MascApi,
    /// Legacy `/rooms/{id}/*` engine endpoints.
    #[allow(dead_code)]
    LegacyEngine,
}

/// Current TRPG backend mode.
///
/// Keep this default on MASC API so the viewer consumes the same protocol/event
/// source used by server-side tool contracts.
pub const TRPG_BACKEND_MODE: TrpgBackendMode = TrpgBackendMode::MascApi;

#[cfg(target_arch = "wasm32")]
pub fn trpg_uses_polling() -> bool {
    matches!(TRPG_BACKEND_MODE, TrpgBackendMode::MascApi)
}

/// URL for initial TRPG state load.
pub fn trpg_state_url() -> String {
    match TRPG_BACKEND_MODE {
        TrpgBackendMode::MascApi => format!(
            "{}/api/v1/trpg/state?room_id={}",
            MASC_MCP_URL, DEFAULT_ROOM_ID
        ),
        TrpgBackendMode::LegacyEngine => trpg_room_url("/state"),
    }
}

/// URL for incremental TRPG stream reads.
#[cfg(target_arch = "wasm32")]
pub fn trpg_stream_poll_url(after_seq: i64) -> String {
    match TRPG_BACKEND_MODE {
        TrpgBackendMode::MascApi => format!(
            "{}/api/v1/trpg/stream?room_id={}&after_seq={}",
            MASC_MCP_URL, DEFAULT_ROOM_ID, after_seq
        ),
        TrpgBackendMode::LegacyEngine => trpg_room_url("/stream"),
    }
}

/// SSE endpoint for a given viewer mode.
/// Returns `None` for Lobby (no live data connection).
/// Called by `masc_client::setup_masc_sse` (wasm32 only).
#[cfg(target_arch = "wasm32")]
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

/// TRPG-specific room URL helper (used by game state loader).
pub fn trpg_room_url(path: &str) -> String {
    format!("{}/rooms/{}{}", TRPG_ENGINE_URL, DEFAULT_ROOM_ID, path)
}
