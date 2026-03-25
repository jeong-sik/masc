// Centralized dashboard constants.
// Change a value here to adjust behavior across the entire dashboard.

// --- HTTP timeouts (milliseconds) ---
// Backend dashboard timeout is 30s; frontend must wait slightly longer.
export const DEFAULT_GET_TIMEOUT_MS = 35_000
export const DEFAULT_POST_TIMEOUT_MS = 30_000
export const DEFAULT_MCP_TIMEOUT_MS = 60_000
export const ROOM_TRUTH_GET_TIMEOUT_MS = 30_000
export const KEEPER_MESSAGE_TIMEOUT_MS = 90_000
export const SOCIAL_SWEEP_TIMEOUT_MS = 45_000

// --- SSE reconnection ---
export const RECONNECT_BASE_MS = 1_000
export const RECONNECT_MAX_MS = 15_000

// --- Refresh & debounce (milliseconds) ---
export const SHELL_TTL_MS = 5_000
export const EXECUTION_TTL_MS = 30_000
export const HEARTBEAT_STALE_MS = 120_000

// --- Buffer & cache sizes ---
export const MAX_JOURNAL_ENTRIES = 200
export const OAS_AGENT_EVENT_BUFFER = 50
export const OAS_KEEPER_SNAPSHOT_MAX = 20

// --- Text truncation (characters) ---
export const TRIM_TEXT_DEFAULT = 120
export const TRUNCATE_DEFAULT = 260
