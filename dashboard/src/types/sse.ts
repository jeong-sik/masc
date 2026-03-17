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
  | 'unknown'

export interface JournalEntry {
  agent: string
  text: string
  timestamp: number
  kind?: 'board' | 'tasks' | 'keepers' | 'system'
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
  | 'home'
  | 'mission'
  | 'proof'
  | 'execution'
  | 'tools'
  | 'live'
  | 'memory'
  | 'governance'
  | 'planning'
  | 'intervene'
  | 'command'
  | 'lab'
  | 'social'
  | 'agent-roster'
  | 'keeper-roster'

export const VALID_TABS: TabId[] = [
  'home',
  'mission',
  'proof',
  'execution',
  'tools',
  'live',
  'memory',
  'governance',
  'planning',
  'intervene',
  'command',
  'lab',
  'social',
  'agent-roster',
  'keeper-roster',
]

// --- Social Graph types ---

export interface SocialGraphNode {
  id: string
  label: string
  type: string
  weight: number
  kind: string
  status: string
}

export interface SocialGraphEdge {
  source: string
  target: string
  type: string
  weight: number
  kind: string
  active: boolean
}

export interface SocialGraphTimelineEvent {
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

export interface SocialGraphStats {
  [key: string]: number
}

export interface SocialGraphResponse {
  nodes: SocialGraphNode[]
  edges: SocialGraphEdge[]
  stats: SocialGraphStats
  timeline: SocialGraphTimelineEvent[]
  generated_at: string
  window: { start: number; end: number; limit: number; room_id: string }
}
