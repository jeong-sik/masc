// MASC Dashboard — keeper tool stats (server-side aggregation).
// Extracted from dashboard.ts. Public symbols re-exported from dashboard.ts.

import { isRecord } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'
import { decodeTelemetryFreshnessMetadata, type TelemetryFreshnessMetadata } from './dashboard-shared'
import {
  decodeTrajectoryCount,
  decodeTrajectoryNonBlankString,
  decodeTrajectoryInvalidReasons,
  decodeTrajectoryReadErrors,
  trajectoryInvalidReasonCount,
  type TrajectoryInvalidReasons,
  type TrajectoryReadError,
} from './dashboard-keeper-trajectory'

export type ToolStat = {
  name: string
  call_count: number
  success_count: number
  failure_count: number
  avg_duration_ms: number
  p95_duration_ms: number
  max_duration_ms: number
  last_used_at: string
}

export type HourlyBucket = {
  hour: string
  call_count: number
  error_count: number
}

export type ToolStatsResponse = TelemetryFreshnessMetadata & {
  keeper: string
  window_hours: number
  total_entries: number
  gate_decode: {
    passed_gate_count: number
    rejected_gate_count: number
    invalid_entry_count: number
    invalid_reasons: TrajectoryInvalidReasons
  }
  io_errors: TrajectoryReadError[]
  tools: ToolStat[]
  timeline: HourlyBucket[]
}

function decodeToolStat(raw: unknown): ToolStat | null {
  if (!isRecord(raw)) return null
  const name = decodeTrajectoryNonBlankString(raw.name)
  const callCount = decodeTrajectoryCount(raw.call_count)
  const successCount = decodeTrajectoryCount(raw.success_count)
  const failureCount = decodeTrajectoryCount(raw.failure_count)
  const avgDurationMs = decodeTrajectoryCount(raw.avg_duration_ms)
  const p95DurationMs = decodeTrajectoryCount(raw.p95_duration_ms)
  const maxDurationMs = decodeTrajectoryCount(raw.max_duration_ms)
  const lastUsedAt = decodeTrajectoryNonBlankString(raw.last_used_at)
  if (
    name === null
    || callCount === null
    || successCount === null
    || failureCount === null
    || avgDurationMs === null
    || p95DurationMs === null
    || maxDurationMs === null
    || lastUsedAt === null
    || successCount + failureCount !== callCount
  ) return null
  return {
    name,
    call_count: callCount,
    success_count: successCount,
    failure_count: failureCount,
    avg_duration_ms: avgDurationMs,
    p95_duration_ms: p95DurationMs,
    max_duration_ms: maxDurationMs,
    last_used_at: lastUsedAt,
  }
}

function decodeHourlyBucket(raw: unknown): HourlyBucket | null {
  if (!isRecord(raw)) return null
  const hour = decodeTrajectoryNonBlankString(raw.hour)
  const callCount = decodeTrajectoryCount(raw.call_count)
  const errorCount = decodeTrajectoryCount(raw.error_count)
  if (hour === null || callCount === null || errorCount === null || errorCount > callCount) return null
  return {
    hour,
    call_count: callCount,
    error_count: errorCount,
  }
}

function decodeToolStatsResponse(raw: unknown): ToolStatsResponse | null {
  if (!isRecord(raw)) return null
  const keeper = decodeTrajectoryNonBlankString(raw.keeper)
  const windowHours = decodeTrajectoryCount(raw.window_hours)
  const totalEntries = decodeTrajectoryCount(raw.total_entries)
  const gateDecode = raw.gate_decode
  if (
    keeper === null
    || windowHours === null
    || windowHours === 0
    || totalEntries === null
    || !isRecord(gateDecode)
  ) return null
  const passedGateCount = decodeTrajectoryCount(gateDecode.passed_gate_count)
  const rejectedGateCount = decodeTrajectoryCount(gateDecode.rejected_gate_count)
  const invalidEntryCount = decodeTrajectoryCount(gateDecode.invalid_entry_count)
  const invalidReasons = decodeTrajectoryInvalidReasons(gateDecode.invalid_reasons)
  if (
    passedGateCount === null
    || rejectedGateCount === null
    || invalidEntryCount === null
    || invalidReasons === null
  ) return null
  if (
    passedGateCount + rejectedGateCount !== totalEntries
    || trajectoryInvalidReasonCount(invalidReasons) !== invalidEntryCount
  ) return null
  const ioErrors = decodeTrajectoryReadErrors(raw.io_errors)
  if (ioErrors === null) return null
  if (!Array.isArray(raw.tools) || !Array.isArray(raw.timeline)) return null
  const tools: ToolStat[] = []
  for (const item of raw.tools) {
    const decoded = decodeToolStat(item)
    if (decoded === null) return null
    tools.push(decoded)
  }
  const timeline: HourlyBucket[] = []
  for (const item of raw.timeline) {
    const decoded = decodeHourlyBucket(item)
    if (decoded === null) return null
    timeline.push(decoded)
  }
  if (
    tools.reduce((sum, tool) => sum + tool.call_count, 0) !== totalEntries
    || timeline.reduce((sum, bucket) => sum + bucket.call_count, 0) !== totalEntries
  ) return null
  return {
    ...decodeTelemetryFreshnessMetadata(raw),
    keeper,
    window_hours: windowHours,
    total_entries: totalEntries,
    gate_decode: {
      passed_gate_count: passedGateCount,
      rejected_gate_count: rejectedGateCount,
      invalid_entry_count: invalidEntryCount,
      invalid_reasons: invalidReasons,
    },
    io_errors: ioErrors,
    tools,
    timeline,
  }
}

export function fetchKeeperToolStats(
  name: string,
  windowHours?: number,
  opts?: AbortableRequestOptions,
): Promise<ToolStatsResponse> {
  const params = windowHours != null ? `?window_hours=${windowHours}` : ''
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/tool-stats${params}`,
    { signal: opts?.signal },
  ).then((raw) => {
    const decoded = decodeToolStatsResponse(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper tool stats payload')
    return decoded
  })
}
