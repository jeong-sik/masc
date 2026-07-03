// Centralized dashboard constants.
// Change a value here to adjust behavior across the entire dashboard.

// --- MASC server defaults ---
// SSOT: ~/me/instructions/workspaces.md Infrastructure Endpoints
export const DEFAULT_MASC_HOST = 'localhost'
export const DEFAULT_MASC_PORT = 8935
export const DEFAULT_MASC_ORIGIN = `http://${DEFAULT_MASC_HOST}:${DEFAULT_MASC_PORT}`

// --- OAS event namespace ---
// SSE event types emitted by the OAS keeper runtime are namespaced with this
// prefix (e.g. "oas:context_compacted"). Single source so the prefix string and
// its strip length stay in sync across the parser and ingress guards.
export const OAS_EVENT_PREFIX = 'oas:'

// --- HTTP timeouts (milliseconds) ---
// Backend dashboard timeout is 30s; frontend must wait slightly longer.
export const DEFAULT_GET_TIMEOUT_MS = 35_000
export const DEFAULT_POST_TIMEOUT_MS = 30_000
export const KEEPER_LIFECYCLE_TIMEOUT_MS = 12_000
export const DEFAULT_MCP_TIMEOUT_MS = 60_000
export const NAMESPACE_TRUTH_GET_TIMEOUT_MS = 30_000
export const KEEPER_MESSAGE_TIMEOUT_MS = 90_000
export const SOCIAL_SWEEP_TIMEOUT_MS = 45_000
export const MCP_INITIALIZE_TIMEOUT_MS = 10_000
export const MCP_INITIALIZED_NOTIFY_TIMEOUT_MS = 5_000
export const MCP_INIT_COOLDOWN_MS = 2_000
// Dashboard WS JSON-RPC timeout. Matches the backend dashboard handler budget
// so a slow first response under Executor_pool contention is not turned into
// a reconnect by the client side.
export const DASHBOARD_WS_RPC_TIMEOUT_MS = 30_000
export const DASHBOARD_WS_HEARTBEAT_INTERVAL_MS = 30_000
// Heartbeat RPCs should resolve quickly; a shorter timeout than the generic
// RPC budget lets the client detect a half-open socket before the next beat.
export const DASHBOARD_WS_HEARTBEAT_RPC_TIMEOUT_MS = 10_000
// Number of consecutive failed connection attempts using a cached discovery
// URL before the cache is invalidated and the client falls back to /ws.
export const DASHBOARD_WS_DISCOVERY_CACHE_MAX_FAILURES = 3

// --- Transport retry defaults (shared by all transport implementations) ---
// Exponential backoff for transport-level reconnection.  Distinct from
// RECONNECT_* (which caps at 60s for SSE/dashboard-WS reconnect storms).
export const TRANSPORT_RETRY_BASE_MS = 1_000
export const TRANSPORT_RETRY_MAX_MS = 30_000
export const TRANSPORT_RETRY_JITTER_MS = 1_000
export const TRANSPORT_RETRY_MAX_ATTEMPTS = 10

// --- Reconnect backoff (shared by SSE and dashboard WS) ---
// Cap at 60s with plus/minus 1s jitter to break reconnect storms when the server is
// degraded; fleets of dashboards retrying every 15s synchronously was
// observed to amplify Executor_pool starvation on cold start.
export const RECONNECT_BASE_MS = 1_000
export const RECONNECT_MAX_MS = 60_000
export const RECONNECT_JITTER_MS = 1_000

// --- Refresh & debounce (milliseconds) ---
export const SHELL_TTL_MS = 5_000
export const HEARTBEAT_STALE_MS = 120_000
export const UI_REFRESH_TTL_MS = 1_000
export const MISSION_BRIEFING_POLL_DELAY_MS = 1_500
export const SSE_DEFAULT_DEBOUNCE_MS = 500
export const SSE_ACTIVITY_DEBOUNCE_MS = 2_000
export const SSE_KEEPER_OPERATOR_DEBOUNCE_MS = 600
export const SSE_KEEPER_THREAD_DEBOUNCE_MS = 800
export const SSE_RECONNECT_RETRY_MS = 3_000
export const PERIODIC_REFRESH_DEV_MS = 180_000
export const PERIODIC_REFRESH_PROD_MS = 120_000
export const TELEMETRY_AUTO_REFRESH_MS = 30_000

// --- Context ratio thresholds (fallback defaults) ---
// Runtime values come from /api/v1/dashboard/config (SSOT: lib/config/env_config_runtime.ml).
// These constants are compiled fallbacks used before the config response arrives.
// Consumers should read from config/context-thresholds.ts, not import these directly.
export const CONTEXT_RATIO_CRITICAL = 0.85  // handoff-imminent
export const CONTEXT_RATIO_WARN = 0.70      // preparing
export const CONTEXT_RATIO_COMPACTING = 0.50 // compacting

// --- Keeper UI/runtime limits ---
export const KEEPER_HISTORY_TAIL_MESSAGES = 200
export const KEEPER_STREAM_IDLE_TIMEOUT_MS = 120_000
export const KEEPER_STREAM_IDLE_POLL_MS = 5_000
export const STREAMING_THINKING_PREVIEW_CHARS = 6_000

// --- Buffer & cache sizes (Vite env overridable) ---
// Defaults balance memory/render cost against available history. Users who
// want deeper replay (e.g. OAS telemetry) can raise the ceiling at build
// time without editing this file:
//   VITE_OAS_TELEMETRY_REPLAY_LIMIT=2000 pnpm --filter masc-dashboard build
import { envInt, envString } from './env'

export const MAX_JOURNAL_ENTRIES = envInt('VITE_MAX_JOURNAL_ENTRIES', 200)
export const OAS_AGENT_EVENT_BUFFER = envInt('VITE_OAS_AGENT_EVENT_BUFFER', 50)
export const OAS_KEEPER_SNAPSHOT_MAX = envInt('VITE_OAS_KEEPER_SNAPSHOT_MAX', 20)
export const OAS_TELEMETRY_REPLAY_LIMIT = envInt('VITE_OAS_TELEMETRY_REPLAY_LIMIT', 500)
export const OAS_OPENTELEMETRY_UI_URL = envString('VITE_OAS_OPENTELEMETRY_UI_URL', null)
// Overview telemetry renders a fixed 28-bar sparkline; this bounds raw samples
// per 5-minute bucket before the summary model takes over for totals/freshness.
export const OVERVIEW_TELEMETRY_EVENTS_PER_BUCKET = envInt(
  'VITE_OVERVIEW_TELEMETRY_EVENTS_PER_BUCKET',
  10,
)

// --- Text truncation (characters) ---
export const TRIM_TEXT_DEFAULT = 120
export const TRUNCATE_DEFAULT = 260

// --- TLA+ verification panel poll interval ---
export const TLA_POLL_INTERVAL_MS = 60_000

// --- Default query window (minutes) ---
export const DEFAULT_WINDOW_MINUTES_24H = 1440
