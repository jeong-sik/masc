// --- SSE Events ---

export type SSEEventType =
  | 'agent_joined'
  | 'agent_left'
  | 'broadcast'
  | 'task_update'
  | 'board_post'
  | 'masc/board_post'
  | 'board_comment'
  | 'masc/board_comment'
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
  | 'keeper_tool_call'
  | 'masc/keeper_tool_call'
  | 'keeper_tool_skipped'
  | 'keeper_turn_complete'
  | 'masc/keeper_turn_complete'
  | 'client_input_approved'
  | 'client_input_rejected'
  | 'client_input_updated'
  | 'governance_param_changed'
  | 'approval:pending'
  | 'approval:resolved'
  // OAS bridge events (relayed from Event_bus via oas_sse_bridge)
  | 'oas:masc:autonomy:agent_selected'
  | 'oas:masc:autonomy:agent_decision'
  | 'oas:masc:autonomy:agent_action_executed'
  | 'oas:masc:keeper:snapshot'
  | 'oas:masc:keeper:tick'
  | 'oas:masc:keeper:lifecycle'
  | 'oas:masc:trust_updated'
  | 'oas:masc:reputation_changed'
  | 'oas:agent_started'
  | 'oas:agent_completed'
  | 'oas:tool_called'
  | 'oas:tool_completed'
  | 'oas:turn_started'
  | 'oas:turn_completed'
  | 'oas:context_compacted'
  | 'oas:task_state_changed'
  // Harness observability events (#3165)
  | 'oas:masc:harness:verdict_recorded'
  | 'oas:masc:harness:pre_compact'
  | 'oas:masc:harness:handoff'
  // Server-push snapshot events (proactive cache broadcasts)
  | 'room_truth_snapshot'
  | 'namespace_truth_snapshot'
  | 'execution_snapshot'
  | 'operator_snapshot'
  | 'operator_digest'
  | 'transport_health_snapshot'

export type JournalSeverity = 'debug' | 'info' | 'warn' | 'error' | 'unknown'
export type JournalSource = 'structured' | 'legacy_stderr' | 'legacy_traceln' | 'sse'

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
  author?: string
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
  | 'workspace'
  | 'lab'
  | 'logs'

export const VALID_TABS: TabId[] = [
  'overview',
  'monitoring',
  'command',
  'workspace',
  'lab',
  'logs',
]

// --- Activity Graph types ---

export interface ActivityGraphNode {
  id: string
  label: string
  weight: number
  semantic_weight?: number
  kind: string
  status: string
  last_event_at?: string
  meta?: Record<string, unknown>
}

export interface ActivityGraphEdge {
  id?: string
  source: string
  target: string
  kind: string
  weight: number
  active: boolean
  last_event_at?: string
  meta?: Record<string, unknown>
}

export interface ActivityGraphTimelineEvent {
  kind: string
  actor: Record<string, unknown>
  summary: string
  subject: { id: string; type: string } | null
  ts: number
  ts_iso: string
  seq: number
  room_id: string
  tags: string[]
  payload: Record<string, unknown>
}

export interface ActivityGraphStats {
  [key: string]: number
}

export interface ActivityGraphHeatmap {
  matrix: number[][]
  max: number
  total: number
}

export interface ActivityGraphKindCounts {
  [kind: string]: number
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

export interface ActivityGraphResponse {
  nodes: ActivityGraphNode[]
  edges: ActivityGraphEdge[]
  stats: ActivityGraphStats
  kind_counts: ActivityGraphKindCounts
  heatmap: ActivityGraphHeatmap
  timeline: ActivityGraphTimelineEvent[]
  generated_at: string
  window: { limit: number; room_id: string | null; kinds: string[] }
  stats_history?: Array<{ bucket: number; events: number; active_agents: number; tasks_done: number }>
}

// --- Swimlane types ---

export interface AgentSpan {
  agent: string
  start_ms: number
  end_ms: number
  kind: string
  label: string
  status: string
}

export interface SwimlaneResponse {
  agents: string[]
  spans: AgentSpan[]
  time_range: { min_ms: number; max_ms: number }
}
