// Centralized dashboard constants.
// Change a value here to adjust behavior across the entire dashboard.

// --- HTTP timeouts (milliseconds) ---
// Backend dashboard timeout is 30s; frontend must wait slightly longer.
export const DEFAULT_GET_TIMEOUT_MS = 35_000
export const DEFAULT_POST_TIMEOUT_MS = 30_000
export const DEFAULT_MCP_TIMEOUT_MS = 60_000
export const NAMESPACE_TRUTH_GET_TIMEOUT_MS = 30_000
export const KEEPER_MESSAGE_TIMEOUT_MS = 90_000
export const SOCIAL_SWEEP_TIMEOUT_MS = 45_000
export const ACTIVITY_TIMEOUT_MS = 10_000
export const MCP_INITIALIZE_TIMEOUT_MS = 10_000
export const MCP_INITIALIZED_NOTIFY_TIMEOUT_MS = 5_000
export const MCP_INIT_COOLDOWN_MS = 2_000

// --- SSE reconnection ---
export const RECONNECT_BASE_MS = 1_000
export const RECONNECT_MAX_MS = 15_000

// --- Refresh & debounce (milliseconds) ---
export const SHELL_TTL_MS = 5_000
export const EXECUTION_TTL_MS = 30_000
export const HEARTBEAT_STALE_MS = 120_000
export const UI_REFRESH_TTL_MS = 1_000
export const COMMAND_HELP_TTL_MS = 60_000
export const MISSION_BRIEFING_POLL_DELAY_MS = 1_500
export const SSE_DEFAULT_DEBOUNCE_MS = 500
export const SSE_OPERATOR_DEBOUNCE_MS = 300
export const SSE_ACTIVITY_DEBOUNCE_MS = 2_000
export const SSE_KEEPER_OPERATOR_DEBOUNCE_MS = 600
export const SSE_KEEPER_THREAD_DEBOUNCE_MS = 800
export const SSE_RECONNECT_RETRY_MS = 3_000
export const PERIODIC_REFRESH_DEV_MS = 180_000
export const PERIODIC_REFRESH_PROD_MS = 120_000
export const TELEMETRY_AUTO_REFRESH_MS = 30_000

// --- Context ratio thresholds ---
// Lifecycle state thresholds (SSOT: lib/config/env_config_runtime.ml Dashboard module)
// Env vars: MASC_DASHBOARD_CTX_HANDOFF_IMMINENT, MASC_DASHBOARD_CTX_PREPARING, MASC_DASHBOARD_CTX_COMPACTING
export const CONTEXT_RATIO_CRITICAL = 0.85  // handoff-imminent
export const CONTEXT_RATIO_WARN = 0.70      // preparing
export const CONTEXT_RATIO_COMPACTING = 0.50 // compacting
// Fleet overview coloring (intermediate between warn and compacting)
export const CONTEXT_RATIO_FLEET_WARN = 0.60

// --- Trajectory timeline ---
export const TRAJECTORY_HEARTBEAT_STALE_MS = 30_000
export const LIVENESS_TICK_MS = 5_000

// --- Keeper UI/runtime limits ---
export const KEEPER_STATUS_TAIL_MESSAGES = 50
export const KEEPER_HISTORY_TAIL_MESSAGES = 200
export const KEEPER_STREAM_IDLE_TIMEOUT_MS = 120_000
export const KEEPER_STREAM_IDLE_POLL_MS = 5_000
export const KEEPER_REPLY_PREVIEW_MAX = 200

// --- Buffer & cache sizes ---
export const MAX_JOURNAL_ENTRIES = 200
export const OAS_AGENT_EVENT_BUFFER = 50
export const OAS_KEEPER_SNAPSHOT_MAX = 20
export const OAS_TELEMETRY_REPLAY_LIMIT = 500

// --- Text truncation (characters) ---
export const TRIM_TEXT_DEFAULT = 120
export const TRUNCATE_DEFAULT = 260

// --- Heatmap color scale (5-level: empty → max intensity) ---
export const HEATMAP_COLORS = [
  '#1e293b', // 0 events
  '#0e4a5c', // 1-25%
  '#0e6e7e', // 26-50%
  '#14919b', // 51-75%
  '#22d3ee', // 76-100%
] as const

// --- Autoresearch form defaults ---
export const AUTORESEARCH_DEFAULT_MAX_CYCLES = 100
export const AUTORESEARCH_DEFAULT_CYCLE_TIMEOUT_S = 300
export const AUTORESEARCH_DEFAULT_MODEL = 'glm'
