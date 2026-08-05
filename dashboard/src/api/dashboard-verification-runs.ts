// MASC Dashboard — completion-authority review registry fetcher + decoder.
//
// Backend: lib/verification_run_registry.ml (RFC-0361 D4)
// Route:   GET /api/v1/dashboard/verification-runs
//
// Sibling of dashboard-fusion.ts and deliberately shaped the same way. Distinct
// from the verification *requests* surface (dashboard-misc.ts): a request is
// what a Keeper submitted, a run is what the completion authority did with it.
// Only the registry shows a review that produced no verdict at all.

import { isRecord, asInt, asNumber, asRecordArray, asString } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'

/** How a completion-authority review ended, mirroring the backend
    Verification_run_registry.status_label vocabulary.

    `unknown` is not a backend label. The backend emits a closed set, so an
    unrecognized value can only come from a protocol break; mapping it to a real
    outcome would let a garbled row pose as an approval or misattribute a
    failure. See CLAUDE.md "Unknown → Permissive Default". */
export type VerificationRunStatusLabel =
  | 'running'
  | 'approved'
  | 'rejected'
  | 'contract_rejected'
  | 'not_reviewed'
  | 'commit_failed'
  | 'raised'
  | 'unknown'

const BACKEND_STATUSES: readonly string[] = [
  'running',
  'approved',
  'rejected',
  'contract_rejected',
  'not_reviewed',
  'commit_failed',
  'raised',
]

/** One tracked review from the registry.

    `cause` is the operator-readable reason the outcome happened, flattened from
    the backend's per-outcome field (`reason` on a rejection, `detail` on the
    failure shapes). Absent on `running` and `approved` — those are the only two
    outcomes with nothing to explain. */
export interface VerificationRunRecord {
  verificationId: string
  taskId: string
  producer: string
  authorityKind: string
  authorityActor: string
  startedAt: number // unix seconds
  status: VerificationRunStatusLabel
  elapsedSeconds?: number
  evaluatorRuntime?: string
  cause?: string
  /** Which gate declined to produce a verdict; `not_reviewed` rows only. */
  gate?: string
}

export interface DashboardVerificationRunsResponse {
  runs: VerificationRunRecord[]
  count: number
  generatedAt: string | null
}

function asVerificationRunStatus(value: unknown): VerificationRunStatusLabel {
  return typeof value === 'string' && BACKEND_STATUSES.includes(value)
    ? (value as VerificationRunStatusLabel)
    : 'unknown'
}

export function parseVerificationRunsResponse(raw: unknown): DashboardVerificationRunsResponse {
  const root = isRecord(raw) ? raw : {}
  const runs: VerificationRunRecord[] = asRecordArray(root.runs)
    .map(row => ({
      verificationId: asString(row.verification_id) ?? '',
      taskId: asString(row.task_id) ?? '',
      producer: asString(row.producer) ?? '',
      authorityKind: asString(row.authority_kind) ?? '',
      authorityActor: asString(row.authority_actor) ?? '',
      startedAt: asNumber(row.started_at) ?? 0,
      status: asVerificationRunStatus(row.status),
      elapsedSeconds: asNumber(row.elapsed_s),
      evaluatorRuntime: asString(row.evaluator_runtime),
      // The backend names a rejection's cause `reason` and every failure shape's
      // cause `detail`; the panel shows one column either way.
      cause: asString(row.reason) ?? asString(row.detail),
      gate: asString(row.gate),
    }))
    .filter(run => run.verificationId.length > 0)
  return {
    runs,
    count: asInt(root.count) ?? runs.length,
    generatedAt: asString(root.generated_at) ?? null,
  }
}

export async function fetchVerificationRuns(
  opts?: AbortableRequestOptions,
): Promise<DashboardVerificationRunsResponse> {
  const raw = await get<unknown>('/api/v1/dashboard/verification-runs', { signal: opts?.signal })
  return parseVerificationRunsResponse(raw)
}
