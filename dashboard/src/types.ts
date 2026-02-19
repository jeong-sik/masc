// MASC Dashboard — Shared type definitions
// Extracted from the existing vanilla JS dashboard globals

// --- Core entities ---

export interface Agent {
  name: string
  status: 'active' | 'idle' | 'inactive' | 'offline'
  current_task: string | null
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
  assignee?: string
  description?: string
  created_at?: string
  updated_at?: string
}

export interface Message {
  id?: string
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

// --- Keeper / Lodge ---

export interface Keeper {
  name: string
  emoji: string
  koreanName?: string
  model?: string
  status: string
  last_heartbeat?: string
  generation?: number
  turn_count?: number
  context_ratio?: number
  traits?: string[]
  interests?: string[]
  primaryValue?: string
  activityLevel?: number
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

export interface TrpgState {
  session?: TrpgSession
  current_round?: TrpgRound
  map?: string
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
  room: string
  paused: boolean
  version: string
  uptime_seconds: number
  tempo?: string
  tool_call_health?: {
    timeouts: number
    p95_duration_ms: number | null
    window_hours: number
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

export type TabId = 'overview' | 'board' | 'activity' | 'agents' | 'tasks' | 'journal' | 'trpg'

export const VALID_TABS: TabId[] = ['overview', 'board', 'activity', 'agents', 'tasks', 'journal', 'trpg']
