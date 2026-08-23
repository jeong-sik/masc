// MASC Dashboard — operator completion verdict mutation.
//
// Backend: lib/server/server_routes_http_routes_verification.ml
// Route:   POST /api/v1/verification/verdict
// Body:    { task_id, verdict: "approve" | "reject", reason?, notes? }
//   - reject requires a non-empty reason; notes is optional free text.
// Response: { ok: true, message, noop } — noop=true when the task had already
//   left awaiting_verification before the verdict landed.
// Auth: token-bound CanAdmin (the bearer token is attached by core.post).

import { isRecord } from '../components/common/normalize'
import { post } from './core'

export type VerificationVerdictDecision = 'approve' | 'reject'

export interface SubmitVerificationVerdictRequest {
  taskId: string
  decision: VerificationVerdictDecision
  /** Required for reject; ignored for approve. */
  reason?: string
  notes?: string
}

export interface SubmitVerificationVerdictResponse {
  ok: true
  message: string
  noop: boolean
}

function verdictProtocolDrift(detail: string): never {
  throw new Error(`invalid verification verdict response: ${detail}`)
}

function decodeSubmitVerificationVerdictResponse(
  raw: unknown,
): SubmitVerificationVerdictResponse {
  if (!isRecord(raw)) return verdictProtocolDrift('expected an object')
  const keys = Object.keys(raw).sort()
  if (keys.length !== 3 || keys.some((k, i) => k !== ['message', 'noop', 'ok'][i])) {
    return verdictProtocolDrift('fields must be exactly ok, message, noop')
  }
  if (raw.ok !== true) return verdictProtocolDrift('ok must be true')
  if (typeof raw.message !== 'string' || raw.message.trim() === '') {
    return verdictProtocolDrift('message must be a non-empty string')
  }
  if (typeof raw.noop !== 'boolean') return verdictProtocolDrift('noop must be a boolean')
  return { ok: true, message: raw.message, noop: raw.noop }
}

export async function submitVerificationVerdict(
  request: SubmitVerificationVerdictRequest,
): Promise<SubmitVerificationVerdictResponse> {
  const body: Record<string, unknown> = {
    task_id: request.taskId,
    verdict: request.decision,
  }
  if (request.decision === 'reject') body.reason = request.reason ?? ''
  if (typeof request.notes === 'string' && request.notes.trim() !== '') {
    body.notes = request.notes.trim()
  }
  const raw = await post<unknown>('/api/v1/verification/verdict', body)
  return decodeSubmitVerificationVerdictResponse(raw)
}
