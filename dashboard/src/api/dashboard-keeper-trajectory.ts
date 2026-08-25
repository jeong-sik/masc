// MASC Dashboard — keeper trajectory (tool call history).
// Extracted from dashboard.ts. Public symbols re-exported from dashboard.ts.

import { get } from './core'

type TrajectoryGate = {
  status: 'pass' | 'reject'
  reason?: string
}

export type TrajectoryEntry = {
  type?: 'thinking'  // absent for tool calls, 'thinking' for thinking blocks
  ts: number
  ts_iso: string
  turn: number
  // RFC-0233: canonical execution identity minted at dispatch (absent on pre-PR-1 rows)
  execution_id?: string
  // Tool-call fields (absent on thinking entries)
  round?: number
  tool_name?: string
  args?: Record<string, unknown> | string
  gate?: TrajectoryGate
  result?: string | null
  duration_ms?: number
  error?: string | null
  // Metadata-only reasoning fields. Content is always null when withheld.
  content?: null
  content_withheld?: boolean
  observation?: 'withheld'
  reasoning_kind?: 'thinking' | 'reasoning_details' | 'redacted_thinking'
  present?: boolean
  char_count?: number
  identity?: { source: 'trajectory_block'; block_index: number }
  redacted?: boolean
}

export type TrajectoryResponse = {
  keeper: string
  trace_id: string
  generation: number
  total_entries: number
  showing: number
  entries: TrajectoryEntry[]
}

export function fetchKeeperTrajectory(
  name: string,
  limit?: number,
  includeThinking = true,
  fullOutput = false,
): Promise<TrajectoryResponse> {
  const params = new URLSearchParams()
  if (limit != null) params.set('limit', String(limit))
  // Always send include_thinking explicitly — backend defaults to false,
  // so omitting the param means "don't include".
  params.set('include_thinking', includeThinking ? 'true' : 'false')
  // Request full output for session trace detail view.
  if (fullOutput) {
    params.set('result_max_len', '10000')
  }
  const qs = params.toString()
  return get<TrajectoryResponse>(
    `/api/v1/keepers/${encodeURIComponent(name)}/trajectory${qs ? `?${qs}` : ''}`,
  )
}
