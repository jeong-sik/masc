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
  cost_usd?: number
  // Thinking-specific fields
  content?: string
  content_length?: number
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
  // content_max_len=0 → no cap: surface the COMPLETE reasoning text in the
  // detail view (남김없이). The backend persists thinking untruncated and
  // treats 0 as "no truncation"; size is intentionally accepted here, this is
  // the drill-in surface (the timeline list keeps the default preview cap).
  if (fullOutput) {
    params.set('result_max_len', '10000')
    params.set('content_max_len', '0')
  }
  const qs = params.toString()
  return get<TrajectoryResponse>(
    `/api/v1/keepers/${encodeURIComponent(name)}/trajectory${qs ? `?${qs}` : ''}`,
  )
}
