// --- SSE Events ---

// Runtime SSOT for exact non-pattern event names accepted from the server.
// Keep the open OAS families below for relayed custom/durable namespaces.
export const SSE_EVENT_TYPES = [
  'agent_joined',
  'agent_left',
  'broadcast',
  // Legacy/live namespaced compatibility variants still emitted by inline dispatch.
  'masc/agent_joined',
  'masc/agent_left',
  'masc/broadcast',
  'task_update',
  'board_post',
  'masc/board_post',
  'board_comment',
  'masc/board_comment',
  'board_delete',
  'masc/board_delete',
  // Path A board events (notifications/board envelope, unwrapped to params.type)
  'post_created',
  'comment_added',
  'post_voted',
  'comment_voted',
  'heartbeat',
  'keeper_heartbeat',
  'keeper_handoff',
  'masc/keeper_handoff',
  'keeper_compaction',
  'masc/keeper_compaction',
  'keeper_guardrail',
  'masc/keeper_guardrail',
  'keeper_phase_changed',
  'keeper_composite_changed',
  'keeper_tool_call',
  'masc/keeper_tool_call',
  'keeper_tool_skipped',
  'keeper_turn_complete',
  'masc/keeper_turn_complete',
  'client_input_approved',
  'client_input_rejected',
  'client_input_updated',
  'governance_param_changed',
  'approval:pending',
  'approval:resolved',
  // OAS bridge events (relayed from Event_bus via oas_sse_bridge)
  'oas:agent_started',
  'oas:agent_completed',
  'oas:agent_failed',
  'oas:tool_called',
  'oas:tool_completed',
  'oas:turn_started',
  'oas:turn_completed',
  'oas:handoff_requested',
  'oas:handoff_completed',
  'oas:context_compacted',
  'oas:context_overflow_imminent',
  'oas:context_compact_started',
  'oas:content_replacement_replaced',
  'oas:content_replacement_kept',
  'oas:slot_scheduler_observed',
  'oas:task_state_changed',
  // Harness observability events (#3165)
  'oas:masc:harness:verdict_recorded',
  'oas:masc:harness:pre_compact',
  'oas:masc:harness:handoff',
  // Known MASC custom events currently projected in the dashboard.
  'oas:masc:autonomy:agent_selected',
  'oas:masc:autonomy:agent_decision',
  'oas:masc:autonomy:agent_action_executed',
  'oas:masc:keeper:snapshot',
  'oas:masc:keeper:lifecycle',
  'oas:masc:trust_updated',
  'oas:masc:reputation_changed',
  // Server-push snapshot events (proactive cache broadcasts)
  'room_truth_snapshot',
  'namespace_truth_snapshot',
  'execution_snapshot',
  'operator_snapshot',
  'operator_digest',
  'transport_health_snapshot',
] as const

type StaticSSEEventType = typeof SSE_EVENT_TYPES[number]
type OpenSSEEventType = `oas:masc:${string}` | `oas:durable:${string}`

export type SSEEventType = StaticSSEEventType | OpenSSEEventType

export function isKnownSSEEventType(value: string): value is StaticSSEEventType {
  return (SSE_EVENT_TYPES as readonly string[]).includes(value)
}

export function isOpenSSEEventType(value: string): value is OpenSSEEventType {
  return value.startsWith('oas:masc:') || value.startsWith('oas:durable:')
}

export type JournalSeverity = 'debug' | 'info' | 'warn' | 'error' | 'unknown'
export type JournalSource = 'structured' | 'legacy_stderr' | 'legacy_traceln' | 'sse'

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
  severity?: JournalSeverity | string
  source?: JournalSource | string
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
  voter?: string
  direction?: 'up' | 'down' | string
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
  trigger?: string
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
}

// --- Journal ---

export type JournalEventType =
  | 'agent_joined'
  | 'agent_left'
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
  | 'overview'
  | 'monitoring'
  | 'command'
  | 'connectors'
  | 'workspace'
  | 'lab'
  | 'logs'

export const VALID_TABS: TabId[] = [
  'overview',
  'monitoring',
  'command',
  'connectors',
  'workspace',
  'lab',
  'logs',
]

// --- Activity Graph types ---
// The response shapes for `/api/v1/activity/graph` and
// `/api/v1/activity/swimlane` are defined as valibot schemas in
// `src/api/schemas/actions-activity.ts`; re-exported here so the
// barrel (`src/types.ts`) surface stays stable for consumers.
import type {
  ActivityGraphNode,
  ActivityGraphEdge,
  ActivityGraphTimelineEvent,
  ActivityGraphStats,
  ActivityGraphHeatmap,
  ActivityGraphKindCounts,
  ActivityGraphResponse,
  AgentSpan,
  SwimlaneResponse,
} from '../api/schemas/actions-activity'

export type {
  ActivityGraphNode,
  ActivityGraphEdge,
  ActivityGraphTimelineEvent,
  ActivityGraphStats,
  ActivityGraphHeatmap,
  ActivityGraphKindCounts,
  ActivityGraphResponse,
  AgentSpan,
  SwimlaneResponse,
}

export type ActivityCategory =
  | 'task'
  | 'session'
  | 'message'
  | 'board'
  | 'governance'
  | 'lifecycle'
  | 'other'

export interface ActionTimelineGroup {
  id: string
  category: ActivityCategory
  actor: string
  subjectId: string | null
  title: string
  summary: string
  latestTs: string
  latestTsMs: number
  rawCount: number
  kinds: string[]
  rawEvents: ActivityGraphTimelineEvent[]
}

// --- Swimlane types ---
// `AgentSpan` and `SwimlaneResponse` are re-exported above from the
// schema file. Keep this divider so future activity-related local
// types have a clear section.
