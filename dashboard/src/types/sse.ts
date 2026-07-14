import type { BoardActorIdentity, BoardPost } from './core'

// --- SSE Events ---

export type SSEEventType =
  | 'agent_bound'
  | 'masc/agent_bound'
  | 'agent_unbound'
  | 'masc/agent_unbound'
  | 'broadcast'
  | 'masc/broadcast'
  | 'task_update'
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
  | 'keeper_compaction'
  | 'masc/keeper_compaction'
  | 'keeper_guardrail'
  | 'masc/keeper_guardrail'
  | 'keeper_phase_changed'
  | 'keeper_composite_changed'
  | 'keeper_chat_appended'
  | 'keeper_chat_queue_changed'
  | 'keeper_tool_call'
  | 'masc/keeper_tool_call'
  | 'keeper_tool_skipped'
  | 'keeper_turn_complete'
  | 'masc/keeper_turn_complete'
  // RFC-0266 Phase 4: fusion run-status transitions pushed to the dashboard.
  | 'fusion_run_status'
  | 'client_input_approved'
  | 'client_input_rejected'
  | 'client_input_updated'
  | 'runtime_param_changed'
  | 'approval:pending'
  | 'approval:resolved'
  // OAS bridge events (relayed from Event_bus via oas_sse_bridge)
  | 'oas:masc:autonomy:agent_selected'
  | 'oas:masc:autonomy:agent_decision'
  | 'oas:masc:autonomy:agent_action_executed'
  | 'oas:masc:keeper:snapshot'
  | 'oas:masc:keeper:lifecycle'
  | 'oas:masc:trust_updated'
  | 'oas:masc:reputation_changed'
  | 'oas:agent_started'
  | 'oas:agent_completed'
  | 'oas:agent_failed'
  | 'oas:tool_called'
  | 'oas:tool_completed'
  | 'oas:turn_started'
  | 'oas:turn_completed'
  | 'oas:handoff_requested'
  | 'oas:handoff_completed'
  | 'oas:context_compacted'
  | 'oas:task_state_changed'
  // Harness observability events (#3165)
  | 'oas:masc:harness:verdict_recorded'
  | 'oas:masc:harness:pre_compact'
  | 'oas:masc:harness:handoff'
  // Forward-compat: the dashboard parser accepts any `oas:*` event so
  // newer runtime bridges do not get dropped at the schema boundary.
  | `oas:${string}`
  // Server-push snapshot events (proactive cache broadcasts)
  | 'project_snapshot'
  | 'namespace_truth_snapshot'
  | 'execution_snapshot'
  | 'operator_snapshot'
  | 'operator_digest'
  | 'transport_health_snapshot'
  // Global audit ledger streaming events (O2 Phase 2)
  | 'audit_event'
  | 'masc/audit_event'
  | 'masc:audit_event'
  | 'oas:masc:audit_event'

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

// Known gate identifiers. Kept open ('string') so new gates can emit without
// a client update, but enumerating canonical values gives us autocomplete and
// catches typos.
export type AttributionGate =
  | 'cdal_verdict'
  | 'verification'
  | 'exec_policy'
  | 'accountability'
  | 'keeper_fsm'
  | 'oas_completion'
  | 'agent_lifecycle'
  | 'task_transition'
  | 'worker_dev_tools'
  | string

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
  // Durable Keeper chat-queue projection invalidation. The event does not
  // carry lifecycle truth; consumers re-read the receipt projection at this
  // exact revision instead of reconstructing queue state from deltas.
  revision?: number
  trigger?: string
  runtime?: string
  reason?: string
  // Keeper phase transition fields
  prev_phase?: string
  new_phase?: string
  event?: string
  // Keeper tool call / tool skip fields
  tool_name?: string
  duration_ms?: number
  success?: boolean
  error_text?: string
  tool_args?: unknown
  tool_result?: unknown
  tool_args_preview?: string
  tool_output_preview?: string
  tool_io_redacted?: boolean
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
  // OAS bridge payload (generic container for Event_bus events)
  payload?: Record<string, unknown>
  // OAS envelope — attached to every oas:* event by oas_sse_bridge since 2.260.0.
  // Used to join events into causal chains in the dashboard journal.
  correlation_id?: string
  // OAS envelope per-run identifier (one per Agent.run invocation).
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
  | 'agent_bound'
  | 'agent_unbound'
  | 'broadcast'
  | 'task_update'
  | 'board_post'
  | 'board_comment'
  | 'board_delete'
  | 'board_vote'
  | 'keeper_heartbeat'
  | 'keeper_handoff'
  | 'keeper_compaction'
  | 'keeper_guardrail'
  | 'keeper_phase_changed'
  | 'keeper_tool_call'
  | 'oas_keeper_snapshot'
  | 'oas_tool'
  | 'oas_turn'
  | 'oas_context'
  | 'oas_task'
  | 'oas_event'
  | 'unknown'

export interface JournalEntry {
  agent: string
  text: string
  narrativeText?: string
  timestamp: number
  severity?: JournalSeverity
  source?: JournalSource
  kind?: 'board' | 'tasks' | 'keepers' | 'system' | 'oas'
  eventType?: JournalEventType
  author?: string
  preview?: string
  postId?: string
  sessionId?: string
  operationId?: string
  workerRunId?: string
  // OAS envelope — propagated from oas_sse_bridge so the journal can group
  // consecutive entries belonging to the same logical run.
  correlationId?: string
  // OAS envelope per-run identifier (one per Agent.run invocation).
  runId?: string
  // OAS envelope event timestamp (Unix epoch seconds, from envelope, not local clock).
  oasTs?: number
}

// --- Sort modes ---

export type BoardSortMode = 'hot' | 'trending' | 'recent' | 'updated' | 'discussed'

// --- Route state ---

export interface RouteState {
  tab: TabId
  params: Record<string, string>
  postId: string | null
}

export type TabId =
  | 'cockpit'
  | 'overview'
  | 'monitoring'
  | 'keepers'
  | 'registry'
  | 'board'
  | 'schedule'
  | 'fusion'
  | 'command'
  | 'connectors'
  | 'workspace'
  | 'lab'
  | 'code'
  | 'logs'
  | 'settings'
  | 'approvals'

export const VALID_TABS: TabId[] = [
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
]
