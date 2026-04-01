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
  portrait?: string
  background?: string
  traits?: string[]
  skills?: string[]
  stats?: TrpgCharacterStats
  stats_raw?: Record<string, number>
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

// --- MDAL (Metric-Driven Agent Loop) ---

export type MdalEvidenceStatus = 'verified' | 'legacy_unverified'

export interface MdalIterationEvidence {
  worker_engine: 'api_tool_loop'
  worker_model: string
  tool_call_count: number
  tool_names: string[]
  session_id: string
  evidence_status: MdalEvidenceStatus
}

export interface MdalIterationRecord {
  iteration: number
  metric_before: number
  metric_after: number
  delta: number
  changes: string
  failed_attempts: string
  next_suggestion: string
  elapsed_ms: number
  cost_usd: number | null
  evidence?: MdalIterationEvidence | null
}

export interface MdalLoop {
  loop_id: string
  profile: string
  status: 'running' | 'interrupted' | 'completed' | 'stopped' | 'error'
  strict_mode?: boolean
  error_message?: string | null
  stop_reason?: string | null
  current_iteration: number
  max_iterations: number
  baseline_metric: number
  current_metric: number
  target: string
  stagnation_streak: number
  stagnation_limit: number
  elapsed_seconds: number
  updated_at?: string | null
  stopped_at?: string | null
  execution_mode?: 'worker_spawn'
  worker_engine?: 'api_tool_loop' | null
  worker_model?: string | null
  evidence_policy?: 'hard' | 'legacy'
  latest_tool_call_count?: number
  latest_tool_names?: string[]
  session_id?: string | null
  evidence_status?: MdalEvidenceStatus | null
  durability?: 'persistent_backend' | 'memory_only'
  persistence_backend?: 'filesystem' | 'postgres' | 'memory'
  recoverable?: boolean
  history: MdalIterationRecord[]
}

// --- Keeper Runtime ---

export interface KeeperStatus {
  running: boolean
  goal?: string
  turn?: number
  generation?: number
  context_ratio?: number
  model?: string
  cost_usd?: number
}
