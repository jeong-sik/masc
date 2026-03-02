// MASC Dashboard — Shared type definitions
// Extracted from the existing vanilla JS dashboard globals

// --- Core entities ---

export interface Agent {
  name: string
  status: 'active' | 'idle' | 'inactive' | 'offline'
  current_task: string | null
  last_seen?: string
  emoji?: string
  koreanName?: string
  model?: string
  traits?: string[]
  interests?: string[]
  activityLevel?: number
  preferredHours?: number[]
  peakHour?: number
  primaryValue?: string
  personalityHint?: string
}

export interface Task {
  id: string
  title: string
  status: 'todo' | 'in_progress' | 'claimed' | 'done' | 'cancelled'
  priority?: number
  assignee?: string
  description?: string
  created_at?: string
  updated_at?: string
}

export interface Message {
  id?: string
  seq?: number
  from: string
  content: string
  timestamp: string
  type?: string
}

// --- Board ---

export interface BoardPost {
  id: string
  author: string
  title: string
  content: string
  tags: string[]
  votes: number
  vote_balance?: number
  comment_count: number
  created_at: string
  updated_at: string
  flair?: string
  hearth_count?: number
}

export interface BoardComment {
  id: string
  post_id: string
  author: string
  content: string
  created_at: string
}

export interface BoardHearth {
  post_id: string
  agent: string
  created_at: string
}

export interface BoardFlair {
  name: string
  emoji: string
  color: string
}

// --- Keeper Metrics ---

export interface KeeperMetricPoint {
  ts: number
  context_ratio: number
  context_tokens: number
  context_max: number
  latency_ms: number
  generation: number
  channel: string
  is_handoff: boolean
  is_compaction: boolean
  compaction_saved_tokens: number
  compaction_trigger: string | null
  model_used: string
  cost_usd: number
  handoff_to_model: string | null
  handoff_new_generation: number | null
}

export type KeeperLifecycleState =
  | 'active'
  | 'compacting'
  | 'preparing'
  | 'handoff-imminent'
  | 'idle'
  | 'offline'

// --- Keeper SSE Events ---

export interface KeeperHeartbeatEvent {
  type: 'keeper_heartbeat'
  name: string
  generation: number
  context_ratio: number
  ts_unix: number
}

export interface KeeperHandoffEvent {
  type: 'keeper_handoff'
  name: string
  from_generation: number
  to_generation: number
  from_model: string
  to_model: string
  ts_unix: number
}

export interface KeeperCompactionEvent {
  type: 'keeper_compaction'
  name: string
  generation: number
  before_tokens: number
  after_tokens: number
  saved_tokens: number
  trigger: string
  ts_unix: number
}

export interface KeeperGuardrailEvent {
  type: 'keeper_guardrail'
  name: string
  generation: number
  reason: string
  ts_unix: number
}

// --- Keeper Autonomy ---

export type AutonomyLevel = 'L1_Reactive' | 'L2_Suggestive' | 'L3_Guided' | 'L4_Autonomous' | 'L5_Independent'

export interface Goal {
  id: string
  horizon: 'short' | 'mid' | 'long'
  title: string
  metric?: string | null
  target_value?: string | null
  due_date?: string | null
  priority: number
  status: string
  parent_goal_id?: string | null
  last_review_note?: string | null
  last_review_at?: string | null
  created_at: string
  updated_at: string
}

export interface KeeperAutonomyInfo {
  autonomy_level: AutonomyLevel
  active_goal_ids: string[]
  last_autonomous_action_at?: string | null
  autonomous_action_count: number
}

// --- Keeper / Lodge ---

export interface Keeper {
  name: string
  emoji?: string
  koreanName?: string
  agent_name?: string
  trace_id?: string
  model?: string
  primary_model?: string
  active_model?: string
  next_model_hint?: string | null
  status: string
  // Autonomy fields (Phase 2)
  autonomy_level?: AutonomyLevel
  active_goal_ids?: string[]
  last_autonomous_action_at?: string | null
  autonomous_action_count?: number
  created_at?: string
  updated_at?: string
  last_heartbeat?: string
  keeper_age_s?: number
  last_turn_ago_s?: number
  last_handoff_ago_s?: number
  last_compaction_ago_s?: number
  last_proactive_ago_s?: number
  last_proactive_reason?: string | null
  last_drift_reason?: string | null
  drift_count_total?: number
  generation?: number
  turn_count?: number
  context_ratio?: number
  context_tokens?: number
  context_max?: number
  context_source?: string
  context?: {
    source?: string
    context_ratio?: number
    context_tokens?: number
    context_max?: number
    message_count?: number
    has_checkpoint?: boolean
  }
  traits?: string[]
  interests?: string[]
  primaryValue?: string
  activityLevel?: number
  will?: string | null
  needs?: string | null
  desires?: string | null
  memory_recent_note?: string | null
  conversation_tail_count?: number
  k2k_count?: number
  k2k_mentions?: Array<{ keeper: string; count: number }>
  handoff_count_total?: number
  compaction_count?: number
  last_compaction_saved_tokens?: number
  skill_primary?: string | null
  skill_secondary?: string[]
  skill_reason?: string | null
  metrics_window?: {
    fallback_rate?: number
    model_fallback_rate?: number
    proactive_fallback_rate?: number
    proactive_preview_similarity_avg?: number
    memory_pass_rate?: number
    memory_avg_score?: number
    handoff_count?: number
    compaction_events?: number
    compaction_saved_tokens?: number
    tool_call_count?: number
    [key: string]: unknown
  }
  agent?: {
    name?: string
    status?: string
    current_task?: string | null
    last_seen?: string
    [key: string]: unknown
  }
  // Metrics time-series (from backend metrics_series)
  metrics_series?: KeeperMetricPoint[]
  // TRPG-specific keeper fields
  trpg_stats?: TrpgCharacterStats
  inventory?: string[]
  relationships?: Record<string, string>
}

// --- TRPG ---

export interface TrpgCharacterStats {
  hp: number
  max_hp: number
  mp: number
  max_mp: number
  level: number
  xp: number
  strength: number
  dexterity: number
  constitution: number
  intelligence: number
  wisdom: number
  charisma: number
}

export interface TrpgActor {
  id: string
  name: string
  role: 'dm' | 'player' | 'npc'
  keeper?: string
  archetype?: string
  persona?: string
  traits?: string[]
  skills?: string[]
  stats?: TrpgCharacterStats
  status: string
}

export interface TrpgRound {
  round_number: number
  phase: string
  events: TrpgEvent[]
  timestamp: string
}

export interface TrpgEvent {
  type: string
  actor?: string
  actor_id?: string
  actor_name?: string
  seq?: number
  room_id?: string
  phase?: string
  category?: string
  visibility?: string
  event_id?: string
  content: string
  dice_roll?: DiceRoll
  timestamp: string
}

export interface DiceRoll {
  notation: string
  rolls: number[]
  total: number
  modifier?: number
}

export interface TrpgSession {
  id: string
  room: string
  status: 'active' | 'paused' | 'ended'
  round: number
  actors: TrpgActor[]
  created_at: string
}

export interface TrpgOutcome {
  result: 'victory' | 'defeat' | 'draw'
  reason?: string
  summary?: string
  turn?: number
  phase?: string
}

export interface TrpgJoinGate {
  phase_open: boolean
  min_points: number
  window: string
  last_opened_turn?: number | null
  last_closed_turn?: number | null
}

export interface TrpgContributionEntry {
  actor_id: string
  score: number
  last_reason?: string | null
  reasons?: string[]
}

export interface TrpgState {
  session?: TrpgSession
  current_round?: TrpgRound
  map?: string
  join_gate?: TrpgJoinGate
  contribution_ledger?: TrpgContributionEntry[]
  outcome?: TrpgOutcome
  party: TrpgActor[]
  story_log: TrpgEvent[]
  history: TrpgSession[]
}

// --- Perpetual Agent ---

export interface PerpetualStatus {
  running: boolean
  goal?: string
  turn?: number
  generation?: number
  context_ratio?: number
  model?: string
  cost_usd?: number
}

// --- Council ---

export interface CouncilDebate {
  id: string
  topic: string
  status: string
  argument_count: number
  created_at?: string
}

export interface CouncilSession {
  id: string
  topic: string
  initiator: string
  votes: number
  quorum: number
  threshold?: number
  state?: string
  created_at?: string
}

export interface CouncilDebateSummary {
  id: string
  topic: string
  status: string
  support_count: number
  oppose_count: number
  neutral_count: number
  total_arguments: number
  created_at?: string
  summary_text?: string
}

export interface BoardMonitoring {
  alert_level?: 'ok' | 'warn' | 'bad' | string
  posts_total?: number
  new_posts_24h?: number
  unanswered_posts?: number
  last_activity_age_s?: number | null
  slo_target_age_s?: number
  slo_breached?: boolean
  warn_age_s?: number
  bad_age_s?: number
}

export interface CouncilMonitoring {
  alert_level?: 'ok' | 'warn' | 'bad' | string
  debates_open?: number
  debates_pending?: number
  sessions_active?: number
  sessions_without_quorum?: number
  oldest_open_debate_age_s?: number | null
  last_activity_age_s?: number | null
  slo_target_quorum_age_s?: number
  slo_breached?: boolean
  warn_age_s?: number
  bad_age_s?: number
}

// --- Dashboard batch response ---

export interface DashboardData {
  agents: { agents: Agent[] }
  tasks: { tasks: Task[] }
  messages: { messages: Message[] }
  status: ServerStatus
  keepers: Keeper[] | { keepers: Keeper[] }
  perpetual: PerpetualStatus
}

export interface ServerStatus {
  room?: string
  cluster?: string
  project?: string
  paused?: boolean
  version?: string
  uptime_seconds?: number
  tempo_interval_s?: number
  tempo?: string
  tool_call_health?: {
    timeouts: number
    p95_duration_ms: number | null
    window_hours: number
  }
  alert_thresholds?: {
    proactive_fallback_warn: number
    proactive_fallback_bad: number
    proactive_similarity_warn: number
    proactive_similarity_bad: number
    toast_cooldown_sec: number
  }
  monitoring?: {
    board?: BoardMonitoring
    council?: CouncilMonitoring
  }
  data_quality?: {
    board_contract_ok?: boolean
    council_feed_ok?: boolean
    last_sync_at?: string
  }
}

// --- SSE Events ---

export type SSEEventType =
  | 'agent_joined'
  | 'agent_left'
  | 'broadcast'
  | 'task_update'
  | 'board_post'
  | 'board_comment'
  | 'heartbeat'
  | 'keeper_heartbeat'
  | 'keeper_handoff'
  | 'keeper_compaction'
  | 'keeper_guardrail'

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
}

// --- Journal ---

export interface JournalEntry {
  agent: string
  text: string
  timestamp: number
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
  | 'execution'
  | 'board'
  | 'activity'
  | 'agents'
  | 'tasks'
  | 'goals'
  | 'journal'
  | 'trpg'
  | 'council'

export const VALID_TABS: TabId[] = [
  'overview',
  'execution',
  'board',
  'activity',
  'agents',
  'tasks',
  'goals',
  'journal',
  'trpg',
  'council',
]
