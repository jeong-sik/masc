// MASC Dashboard — Autoresearch API client
// Fetches loop list and detail from dedicated HTTP endpoints.

import { get } from './core'

export interface AutoresearchCycleRecord {
  cycle: number
  hypothesis: string
  score_before: number
  score_after: number
  delta: number
  decision: 'keep' | 'discard'
  commit_hash: string | null
  elapsed_ms: number
  model_used: string
  timestamp: number
}

export interface AutoresearchLoopSummary {
  loop_id: string
  goal: string
  metric_fn: string
  model_model: string
  target_file: string
  status: 'running' | 'completed' | 'stopped' | 'error'
  current_cycle: number
  max_cycles: number
  baseline: number
  best_score: number
  best_cycle: number
  total_keeps: number
  total_discards: number
  elapsed_s: number
  workdir: string
  source_workdir: string
  program_note: string | null
  warnings: string[]
  insights: string[]
  recent_cycles: AutoresearchCycleRecord[]
  error: string | null
  session_id: string | null
  queued_hypothesis: string | null
}

export interface AutoresearchLoopsResponse {
  loops: AutoresearchLoopSummary[]
  total: number
}

export interface AutoresearchLoopDetail extends AutoresearchLoopSummary {
  history: AutoresearchCycleRecord[]
  history_count: number
}

export function fetchAutoresearchLoops(): Promise<AutoresearchLoopsResponse> {
  return get('/api/v1/autoresearch/loops')
}

export function fetchAutoresearchLoopDetail(
  loopId: string,
  historyLimit = 100,
): Promise<AutoresearchLoopDetail> {
  return get(`/api/v1/autoresearch/loops/${encodeURIComponent(loopId)}?history_limit=${historyLimit}`)
}
