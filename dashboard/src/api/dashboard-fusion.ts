// MASC Dashboard — Fusion run registry fetcher + decoder.
// Extracted from dashboard.ts (domain split). Public symbols are re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { isRecord, asInt, asNumber, asRecordArray, asString } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'

/** Status of a tracked fusion deliberation, mirroring the backend
    Fusion_run_registry.status_label vocabulary: a run is `running`, or finished
    `completed` (judge ok) / `failed` (denied / sink-failed / aborted). */
export type FusionRunStatusLabel = 'running' | 'completed' | 'failed'

/** One row of the fusion run registry from GET /api/v1/dashboard/fusion-runs.
    The registry tracks what the board-post view cannot: an in-progress
    deliberation has no board post yet, so only the registry shows it as
    `running`. Distinct from `FusionRunView` (board-meta-derived detail). */
export interface FusionRunRecord {
  runId: string
  keeper: string
  preset: string
  startedAt: number // unix seconds
  status: FusionRunStatusLabel
  // Failure attribution, present only on `failed` rows. The backend emits both
  // as additive fields (Fusion_run_registry.run_to_yojson): `error` is the human
  // failure text, `failure_code` the closed machine tag (timeout / provider_error
  // / …). Absent on running/completed rows.
  error?: string
  failureCode?: string
}

export interface DashboardFusionRunsResponse {
  runs: FusionRunRecord[]
  count: number
  generatedAt: string | null
}

// The backend emits a closed three-label enum, so an unrecognized value can only
// come from a protocol break. Map it to `failed` (conservative: never let a
// garbled row pose as a healthy `completed` or an active `running`) rather than
// to a convenient default — see CLAUDE.md "Unknown → Permissive Default".
function asFusionRunStatus(value: unknown): FusionRunStatusLabel {
  return value === 'running' || value === 'completed' || value === 'failed' ? value : 'failed'
}

export function parseFusionRunsResponse(raw: unknown): DashboardFusionRunsResponse {
  const root = isRecord(raw) ? raw : {}
  const runs: FusionRunRecord[] = asRecordArray(root.runs)
    .map(row => ({
      runId: asString(row.run_id) ?? '',
      keeper: asString(row.keeper) ?? '',
      preset: asString(row.preset) ?? '',
      startedAt: asNumber(row.started_at) ?? 0,
      status: asFusionRunStatus(row.status),
      error: asString(row.error),
      failureCode: asString(row.failure_code),
    }))
    .filter(run => run.runId.length > 0)
  return {
    runs,
    count: asInt(root.count) ?? runs.length,
    generatedAt: asString(root.generated_at) ?? null,
  }
}

export async function fetchFusionRuns(
  opts?: AbortableRequestOptions,
): Promise<DashboardFusionRunsResponse> {
  const raw = await get<unknown>('/api/v1/dashboard/fusion-runs', { signal: opts?.signal })
  return parseFusionRunsResponse(raw)
}
