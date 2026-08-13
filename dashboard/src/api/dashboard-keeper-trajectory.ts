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
): Promise<TrajectoryResponse> {
  const params = new URLSearchParams()
  if (limit != null) params.set('limit', String(limit))
  // Hidden chain-of-thought is not dashboard data. Keep this explicit so a
  // backend default change cannot make raw reasoning cross the HTTP boundary.
  // A separate typed metadata projection may expose presence/counts later.
  params.set('include_thinking', 'false')
  const qs = params.toString()
  return get<TrajectoryResponse>(
    `/api/v1/keepers/${encodeURIComponent(name)}/trajectory${qs ? `?${qs}` : ''}`,
  )
}
