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
  | 'keeper_compaction'
  | 'keeper_guardrail'
  | 'keeper_turn_complete'
  | 'client_input_approved'
  | 'client_input_rejected'
  | 'client_input_updated'
  | 'mdal_started'
  | 'mdal_iteration'
  | 'mdal_completed'
  | 'mdal_stopped'
  | 'governance_param_changed'
  // OAS bridge events (relayed from Event_bus via oas_sse_bridge)
  | 'oas:masc:lodge:agent_selected'
  | 'oas:masc:lodge:agent_decision'
  | 'oas:masc:lodge:agent_action_executed'
  | 'oas:masc:keeper:snapshot'
  | 'oas:masc:keeper:tick'
  | 'oas:masc:keeper:resident_lifecycle'
  | 'oas:masc:trust_updated'
  | 'oas:masc:reputation_changed'

export interface SSEEvent {
  type: SSEEventType
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
  // OAS bridge payload (generic container for Event_bus events)
  payload?: Record<string, unknown>
  // MDAL event fields
  loop_id?: string
  profile?: string
  baseline?: number
  target?: string
  final_metric?: number
  iterations?: number
  iteration?: number
  metric_before?: number
  metric_after?: number
  delta?: number
}

// --- Journal ---

export type JournalEventType =
  | 'agent_joined'
  | 'agent_left'
  | 'broadcast'
  | 'task_update'
  | 'board_post'
  | 'board_comment'
  | 'keeper_heartbeat'
  | 'keeper_handoff'
  | 'keeper_compaction'
  | 'keeper_guardrail'
  | 'oas_keeper_snapshot'
  | 'oas_event'
  | 'unknown'

export interface JournalEntry {
  agent: string
  text: string
  narrativeText?: string
  timestamp: number
  kind?: 'board' | 'tasks' | 'keepers' | 'system' | 'oas'
  eventType?: JournalEventType
  author?: string
  preview?: string
  postId?: string
}

// --- Sort modes ---

export type BoardSortMode = 'hot' | 'trending' | 'recent' | 'updated' | 'discussed'

// --- Route state ---

export interface RouteState {
  tab: TabId
  params: Record<string, string>
  postId: string | null
}


export interface DashboardSemanticMetric {
  id: string
  label: string
  what_it_measures: string
  why_it_exists: string
  source_path: string
  update_trigger: string
  agent_behavior_effect: string
  ecosystem_effect: string
  interpretation: string
  bad_smell: string
  next_action: string
}

export interface DashboardSemanticPanel {
  id: string
  title: string
  purpose: string
  problem_solved: string
  when_active: string
  agent_role: string
  ecosystem_function: string
  related_tools: string[]
  metrics: DashboardSemanticMetric[]
}

export interface DashboardSemanticSurface {
  id: string
  label: string
  purpose: string
  problem_solved: string
  when_active: string
  agent_role: string
  ecosystem_function: string
  panels: DashboardSemanticPanel[]
}

export interface DashboardSemanticsResponse {
  schema_version?: string
  generated_at?: string
  surfaces: DashboardSemanticSurface[]
}

export type TabId =
  | 'overview'
  | 'monitoring'
  | 'command'
  | 'workspace'
  | 'lab'
  | 'logs'

/** Pre-restructure tab IDs kept for redirect aliases. */
export type LegacyTabId =
  | 'home'
  | 'status'
  | 'work'
  | 'operations'
  | 'situation'
  | 'agents'
  | 'activity'
  | 'control'
  | 'mission'
  | 'proof'
  | 'execution'
  | 'tools'
  | 'live'
  | 'memory'
  | 'governance'
  | 'planning'
  | 'intervene'
  | 'social'
  | 'agent-roster'
  | 'keeper-roster'

/** Accepts both new and legacy tab IDs (for navigate() backward compat). */
export type AnyTabId = TabId | LegacyTabId

export const VALID_TABS: TabId[] = [
  'overview',
  'monitoring',
  'command',
  'workspace',
  'lab',
  'logs',
]

/** Maps legacy tab IDs to new tab + optional section params. */
export const LEGACY_TAB_REDIRECTS: Record<LegacyTabId, { tab: TabId; params?: Record<string, string> }> = {
  'home': { tab: 'overview' },
  'status': { tab: 'monitoring', params: { section: 'sessions' } },
  'work': { tab: 'workspace', params: { section: 'board' } },
  'operations': { tab: 'command', params: { section: 'intervene' } },
  'situation': { tab: 'monitoring', params: { section: 'sessions' } },
  'agents': { tab: 'monitoring', params: { section: 'agents' } },
  'activity': { tab: 'monitoring', params: { section: 'activity' } },
  'control': { tab: 'command', params: { section: 'intervene' } },
  'mission': { tab: 'monitoring', params: { section: 'sessions' } },
  'agent-roster': { tab: 'monitoring', params: { section: 'agents' } },
  'execution': { tab: 'monitoring', params: { section: 'sessions' } },
  'keeper-roster': { tab: 'monitoring', params: { section: 'agents' } },
  'live': { tab: 'monitoring', params: { section: 'activity' } },
  'social': { tab: 'monitoring', params: { section: 'activity' } },
  'proof': { tab: 'workspace', params: { section: 'evidence' } },
  'memory': { tab: 'workspace', params: { section: 'board' } },
  'governance': { tab: 'command', params: { section: 'governance' } },
  'planning': { tab: 'workspace', params: { section: 'planning' } },
  'tools': { tab: 'lab', params: { section: 'tools' } },
  'intervene': { tab: 'command', params: { section: 'intervene' } },
}

// --- Activity Graph types ---

export interface ActivityGraphNode {
  id: string
  label: string
  type: string
  weight: number
  kind: string
  status: string
}

export interface ActivityGraphEdge {
  source: string
  target: string
  type: string
  weight: number
  kind: string
  active: boolean
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

export interface ActivityGraphResponse {
  nodes: ActivityGraphNode[]
  edges: ActivityGraphEdge[]
  stats: ActivityGraphStats
  timeline: ActivityGraphTimelineEvent[]
  generated_at: string
  window: { start: number; end: number; limit: number; room_id: string }
}
