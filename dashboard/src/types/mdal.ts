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

