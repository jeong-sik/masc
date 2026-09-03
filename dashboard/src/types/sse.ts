import type { BoardActorIdentity, BoardPost } from './core'

// --- SSE Events ---

export type SSEEventType =
  | 'broadcast'
  | 'masc/broadcast'
  | 'board_post'
  | 'masc/board_post'
  | 'board_comment'
  | 'masc/board_comment'
  | 'board_delete'
  | 'masc/board_delete'
  // Path A board events (notifications/board envelope, unwrapped to params.type)
  | 'post_created'
  | 'comment_added'
  | 'post_voted'
  | 'comment_voted'
  | 'reaction_changed'
  | 'heartbeat'
  | 'keeper_heartbeat'
  | 'keeper_handoff'
  | 'masc/keeper_handoff'
  | 'keeper_phase_changed'
  | 'keeper_composite_changed'
  | 'keeper_chat_appended'
  | 'keeper_chat_operation_event'
  | 'keeper_waiting_inventory_changed'
  | 'agent_core_telemetry_sample'
  | 'keeper_tool_call'
  | 'masc/keeper_tool_call'
  | 'keeper_tool_call_evidence_committed'
  | 'keeper_turn_complete'
  | 'masc/keeper_turn_complete'
  // RFC-0266 Phase 4: fusion run-status transitions pushed to the dashboard.
  | 'fusion_run_status'
  | 'internal_agent_runs_changed'
  | 'runtime_param_changed'
  | 'approval:pending'
  | 'approval:resolved'
  | 'approval:audit'
  | 'approval:summary_updated'
  // Nonhierarchical Gate mode transitions (#24332 governance->gate refactor).
  // Emitted by server_routes_http_routes_dashboard.ml.
  | 'gate_mode_changed'
  // External-services Gate lane transitions (identity-service calls).
  | 'gate_external_mode_changed'
  // Task claim notifications. Emitted by lib/task/tool_task_handlers.ml.
  | 'masc/task_claimed'
  // Agent Core bridge events (relayed from Event_bus via agent_core_sse_bridge)
  | 'agent_core:masc:keeper:lifecycle'
  | 'agent_core:agent_started'
  | 'agent_core:agent_completed'
  | 'agent_core:agent_failed'
  | 'agent_core:tool_called'
  | 'agent_core:tool_completed'
  | 'agent_core:turn_started'
  | 'agent_core:turn_completed'
  | 'agent_core:handoff_requested'
  | 'agent_core:handoff_completed'
  // Harness observability events (#3165)
  | 'agent_core:masc:harness:verdict_recorded'
  | 'agent_core:masc:harness:pre_compact'
  | 'agent_core:masc:harness:handoff'
  // Forward-compat: the dashboard parser accepts any `agent_core:*` event so
  // newer runtime bridges do not get dropped at the schema boundary.
  | `agent_core:${string}`
  // Server-push snapshot events (proactive cache broadcasts)
  | 'project_snapshot'
  | 'execution_snapshot'
  | 'operator_snapshot'
  | 'operator_digest'
  | 'transport_health_snapshot'
  // Global audit ledger streaming events (O2 Phase 2)
  | 'audit_event'
  | 'masc/audit_event'
  | 'masc:audit_event'
  | 'agent_core:masc:audit_event'

export type JournalSeverity = 'debug' | 'info' | 'warn' | 'error' | 'unknown'
// Closed set of journal sources. `'unknown'` is a first-class variant
// (mirroring JournalSeverity) so that `normalizeJournalSource` can fail
// loud on unrecognized wire data instead of silently coercing it to
// `'sse'`. Source of truth: see `normalizeJournalSource` in journal-entry.ts.
export type JournalSource = 'structured' | 'legacy_stderr' | 'legacy_traceln' | 'sse' | 'unknown'

// --- Attribution envelope ---
// Structured verdict metadata for gate decisions. Emitted alongside existing
// reason/reason_code fields so dashboards can trace causality without breaking
// consumers that don't understand the envelope.
//
// OCaml SSOT: lib/attribution.mli (since 2.261.0).
// AttributionOutcome is a discriminated union on 'kind' — each variant
// carries exactly the fields relevant to that outcome (no optional fields
// shared across variants).

export type AttributionOrigin = 'det' | 'nondet'

// The gate a backend attribution record carries. Open by contract: a new
// gate emits without a client update. The union of named values that used to
// sit here ended in '| string', which absorbs every other string, so it
// caught no typo and gave no exhaustiveness — only the appearance of both.
// The gates masc actually emits live in attribution-panel's KNOWN_GATES.
export type AttributionGate = string

// Gate decision outcome. Discriminated union — exhaustive switch on 'kind'.
export type AttributionOutcome =
  | { kind: 'passed' }
  | { kind: 'policy_failed'; reason: string }
  | { kind: 'transition_blocked'; from_state: string; to_state: string; reason: string }
  | { kind: 'partial_pass'; score: number; rationale: string }

export interface Attribution {
  origin: AttributionOrigin
  gate: AttributionGate
  evidence: Record<string, unknown>
  outcome: AttributionOutcome
}

export interface SSEEvent {
  type: SSEEventType
  severity?: JournalSeverity
  source?: JournalSource
  // Originating connector for keeper_chat_appended ('dashboard' |
  // 'discord' | 'slack' | 'agent' | gate channel). Distinct from
  // [source], which is reserved for the journal origin.
  connector?: string
  agent?: string
  from?: string
  from_agent?: string
  message?: string
  content?: string
  task_id?: string
  status?: string
  post_id?: string
  comment_id?: string
  title?: string
  author?: string
  author_identity?: BoardActorIdentity | null
  voter?: string
  voter_identity?: BoardActorIdentity | null
  direction?: 'up' | 'down'
  target_type?: 'post' | 'comment'
  target_id?: string
  user_id?: string
  emoji?: string
  reacted?: boolean
  post_kind?: BoardPost['post_kind']
  hearth?: string
  agent_name?: string
  keeper_name?: string
  keeper_id?: string
  event_type?: string
  // Keeper event fields
  name?: string
  generation?: number
  context_ratio?: number
  ts_unix?: number
  from_generation?: number
  to_generation?: number
  from_model?: string
  to_model?: string
  before_tokens?: number
  after_tokens?: number
  saved_tokens?: number
  // Waiting-inventory invalidation queue kind. The event carries no rows or
  // revision ID; consumers re-read the authoritative projection.
  queue_kind?: 'chat_operation' | 'event_queue'
  trigger?: string
  runtime?: string
  provider_id?: string
  model_id?: string
  reason?: string
  // Keeper phase transition fields
  prev_phase?: string
  new_phase?: string
  event?: string
  // Keeper tool call / tool skip fields
  tool_name?: string
  duration_ms?: number
  disposition?: 'completed' | 'deferred' | 'failed'
  success?: boolean
  error_text?: string
  tool_args?: unknown
  tool_result?: unknown
  tool_args_preview?: string
  tool_output_preview?: string
  tool_io_redacted?: boolean
  composition_tool?: string
  composition_run_id?: string
  composition_node_id?: string
  composition_execution?: 'inline' | 'async'
  parent_tool_use_id?: string
  tool_use_id?: string
  planned_index?: number
  batch_index?: number
  batch_size?: number
  execution_mode?: 'serial' | 'concurrent'
  reason_code?: string
  turn?: number
  phase?: string
  from_state?: string
  to_state?: string
  session_id?: string
  operation_id?: string
  worker_run_id?: string
  // Keeper turn complete enrichment
  model_used?: string
  input_tokens?: number
  output_tokens?: number
  cost_usd?: number
  tool_calls_made?: number
  total_turns?: number
  // Per-turn cache observability (RFC-0382). `cache_read_tokens` is
  // usage-reported (cloud providers); `cache_n`/`prompt_n` are wire timings
  // (llama-server, Ollama): KV-reused vs freshly prefilled prompt tokens.
  cache_read_tokens?: number | null
  cache_n?: number | null
  prompt_n?: number | null
  // Agent Core bridge payload (generic container for Event_bus events).
  payload?: Record<string, unknown> | string
  // Wall-clock time attached to runtime events such as masc/task_claimed.
  timestamp?: number
  // gate_mode_changed: nonhierarchical Gate mode transition fields.
  mode?: string
  previous_mode?: string | null
  actor?: string
  changed_at?: string
  kind?: string
  // Agent Core envelope — attached to every agent_core:* event by agent_core_sse_bridge since 2.260.0.
  // Used to join events into causal chains in the dashboard journal.
  correlation_id?: string
  // Agent Core envelope per-run identifier (one per Agent.run invocation).
  run_id?: string
  // Gate attribution envelope — structured verdict metadata. Emitters
  // attach this alongside existing reason/reason_code fields since 2.261.0.
  // See lib/attribution.mli for OCaml SSOT and evidence schema per gate.
  attribution?: Attribution
  // Global audit ledger fields (O2 Phase 2 — masc.audit_event)
  audit_id?: string
  audit_ts?: string
  audit_actor?: string
  audit_kind?: string
  audit_target?: string
  audit_summary?: string
  audit_severity?: string
  audit_payload?: unknown
  // RFC-0235 P1/P3: synthesized voice clip attached to keeper_chat_appended.
  // Backend emits `audio: { token, mime, message_text, audio_url?,
  // duration_sec?, device_id? }`. Optional; assistant transcript rows
  // render a user-gesture play button when present.
  audio?: SSEAudioClip
  // keeper_chat_operation_event: the same AG-UI payload used by the accepted
  // stream, correlated to exactly one durable operation.
  ag_ui_event?: unknown
}

// RFC-0235 P1: nested audio payload inside `keeper_chat_appended` events.
// Naming mirrors the backend JSON keys; normalizers map to camelCase on
// the way into `KeeperConversationAudioClip`.
export interface SSEAudioClip {
  token: string
  mime: string
  message_text: string
  audio_url?: string | null
  duration_sec?: number | null
  device_id?: string | null
}

// --- Journal ---

export type JournalEventType =
  | 'broadcast'
  | 'board_post'
  | 'board_comment'
  | 'board_delete'
  | 'board_vote'
  | 'keeper_heartbeat'
  | 'keeper_handoff'
  | 'keeper_phase_changed'
  | 'keeper_tool_call'
  | 'agent_core_tool'
  | 'agent_core_turn'
  | 'agent_core_event'
  | 'unknown'

export interface JournalEntry {
  agent: string
  text: string
  narrativeText?: string
  timestamp: number
  severity?: JournalSeverity
  source?: JournalSource
  kind?: 'board' | 'tasks' | 'keepers' | 'system' | 'agentCore'
  eventType?: JournalEventType
  author?: string
  preview?: string
  postId?: string
  sessionId?: string
  operationId?: string
  workerRunId?: string
  // Agent Core envelope — propagated from agent_core_sse_bridge so the journal can group
  // consecutive entries belonging to the same logical run.
  correlationId?: string
  // Agent Core envelope per-run identifier (one per Agent.run invocation).
  runId?: string
  // Agent Core envelope event timestamp (Unix epoch seconds, from envelope, not local clock).
  agentCoreTs?: number
}

// --- Sort modes ---

export type BoardSortMode = 'hot' | 'trending' | 'recent' | 'updated' | 'discussed'

// --- Route state ---

export interface RouteState {
  tab: TabId
  params: Record<string, string>
  postId: string | null
}

export const VALID_TABS = [
  'cockpit',
  'overview',
  'monitoring',
  'keepers',
  'registry',
  'board',
  'schedule',
  'fusion',
  'command',
  'connectors',
  'workspace',
  'lab',
  'code',
  'logs',
  'settings',
  'approvals',
] as const

export type TabId = typeof VALID_TABS[number]
