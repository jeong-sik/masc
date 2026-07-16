// MASC Dashboard — Gate / HITL transport and normalization boundary.
// Public symbols are re-exported from dashboard.ts.

import { ApiRequestError, get, post, withRetries } from './core'
import { isRecord, asBoolean, asInt, asNullableString, asString } from '../components/common/normalize'
import { asNullableIsoTimestamp, normalizeKeeperApprovalQueueItem } from './board'
import { normalizeKeeperResolvedApprovalDecision } from '../lib/keeper-approval-decision'
import type {
  KeeperApprovalRule,
  DashboardGateResponse,
  KeeperApprovalQueueItem,
  KeeperResolvedApprovalItem,
  GateDecisionSource,
  GateMode,
  GateModeStatus,
} from '../types'
import type { AbortableRequestOptions } from './core'

export interface FetchDashboardGateOptions extends AbortableRequestOptions {
  force?: boolean
}

function normalizeKeeperApprovalRule(raw: unknown): KeeperApprovalRule | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id, '').trim()
  const keeperName = asString(raw.keeper_name, '').trim()
  const toolName = asString(raw.tool_name, '').trim()
  if (!id || !keeperName || !toolName) return null
  return {
    id,
    keeper_name: keeperName,
    tool_name: toolName,
    request_fingerprint: asNullableString(raw.request_fingerprint) ?? undefined,
    created_at: asNullableIsoTimestamp(raw.created_at),
    created_by: asNullableString(raw.created_by),
    source_approval_id: asNullableString(raw.source_approval_id),
  }
}

function normalizeGateModeValue(raw: unknown): GateMode | null {
  return raw === 'manual' || raw === 'auto_judge' || raw === 'always_allow' ? raw : null
}

function normalizeGateMode(raw: unknown): GateModeStatus | undefined {
  if (!isRecord(raw)) return undefined
  const mode = normalizeGateModeValue(raw.mode)
  if (!mode) {
    return {
      mode: 'manual',
      state: 'invalid',
      read_error: `unsupported Gate mode: ${String(raw.mode)}`,
    }
  }
  return {
    mode,
    configured: asBoolean(raw.configured) ?? undefined,
    state: asNullableString(raw.state) ?? undefined,
    read_error: asNullableString(raw.read_error) ?? undefined,
  }
}

function normalizeHitlStatus(raw: unknown): DashboardGateResponse['hitl'] | undefined {
  if (!isRecord(raw)) return undefined
  return {
    gate_mode: normalizeGateMode(raw.gate_mode),
  }
}

function normalizeGateDecisionSource(raw: unknown): GateDecisionSource | null {
  return raw === 'always_allowed' || raw === 'auto_judge' || raw === 'human_operator'
    ? raw
    : null
}

function normalizeKeeperResolvedApprovalItem(raw: unknown): KeeperResolvedApprovalItem | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id, '').trim()
  const keeperName = asString(raw.keeper_name, '').trim()
  const toolName = asString(raw.tool_name, '').trim()
  if (!id || !keeperName || !toolName) return null
  const ruleMatch = isRecord(raw.rule_match)
    ? {
        rule_id: asNullableString(raw.rule_match.rule_id),
      }
    : null
  const decisionRaw = asNullableString(raw.decision)
  const decisionKind = asNullableString(raw.decision_kind)
  const decisionReason = asNullableString(raw.decision_reason)
  return {
    id,
    keeper_name: keeperName,
    tool_name: toolName,
    decision: normalizeKeeperResolvedApprovalDecision(decisionKind),
    decision_raw: decisionRaw,
    decision_reason: decisionReason,
    resolved_at: asNullableIsoTimestamp(raw.resolved_at),
    turn_id: asInt(raw.turn_id),
    task_id: asNullableString(raw.task_id),
    goal_id: asNullableString(raw.goal_id),
    goal_ids: Array.isArray(raw.goal_ids)
      ? raw.goal_ids.filter((value): value is string => typeof value === 'string')
      : [],
    decision_source: normalizeGateDecisionSource(raw.decision_source),
    rule_match: ruleMatch,
  }
}

export function fetchDashboardGate(
  opts?: FetchDashboardGateOptions,
): Promise<DashboardGateResponse> {
  return withRetries('fetchDashboardGate', async () => {
    const query = opts?.force ? '?force=1' : ''
    const raw = await get<Record<string, unknown>>(`/api/v1/dashboard/gate${query}`, {
      signal: opts?.signal,
    })
    const approvalQueue = Array.isArray(raw.approval_queue)
      ? raw.approval_queue
          .map(item => normalizeKeeperApprovalQueueItem(item))
          .filter((item): item is KeeperApprovalQueueItem => item !== null)
      : []
    const recentResolved = Array.isArray(raw.recent_resolved)
      ? raw.recent_resolved
          .map(item => normalizeKeeperResolvedApprovalItem(item))
          .filter((item): item is KeeperResolvedApprovalItem => item !== null)
      : []
    const approvalRules = Array.isArray(raw.approval_rules)
      ? raw.approval_rules
          .map(item => normalizeKeeperApprovalRule(item))
          .filter((item): item is KeeperApprovalRule => item !== null)
      : []
    return {
      generated_at: asNullableIsoTimestamp(raw.generated_at) ?? undefined,
      note: typeof raw.note === 'string' && raw.note.trim() !== '' ? raw.note.trim() : undefined,
      approval_queue: approvalQueue,
      recent_resolved: recentResolved,
      approval_rules: approvalRules,
      hitl: normalizeHitlStatus(raw.hitl),
    }
  })
}

export function resolveGateApproval(
  id: string,
  decision: 'approve' | 'reject',
  rememberRule?: boolean,
  reason?: string,
): Promise<{ ok: boolean; id: string; decision: 'approve' | 'reject'; rule_id?: string | null }> {
  return post('/api/v1/dashboard/gate/resolve', {
    id,
    decision,
    remember_rule: rememberRule,
    reason,
  })
}

export function retryGateAutoJudge(
  id: string,
): Promise<{ ok: boolean; id: string }> {
  return post('/api/v1/dashboard/gate/retry', { id })
}

export function deleteGateApprovalRule(
  id: string,
): Promise<{ ok: boolean; id: string }> {
  return post('/api/v1/dashboard/gate/rules/delete', { id })
}

export interface SetGateModeResponse {
  ok: boolean
  mode: GateMode
  previous_mode: GateMode | null
  actor: string
  changed_at: string
  recovery_status: 'completed' | 'failed' | 'not_requested'
  recovery_error: string | null
  reopened: number
  started: number
  queued: number
  replaced_read_error?: string
}

const SET_GATE_MODE_RESPONSE_FIELDS = new Set([
  'ok',
  'mode',
  'previous_mode',
  'actor',
  'changed_at',
  'recovery_status',
  'recovery_error',
  'reopened',
  'started',
  'queued',
  'replaced_read_error',
])

function gateModeProtocolDrift(detail: string): never {
  throw new ApiRequestError({
    method: 'POST',
    path: '/api/v1/dashboard/gate/mode',
    detail: `invalid Gate mode response: ${detail}`,
    errorCode: 'protocol_drift',
  })
}

function nonNegativeSafeInteger(raw: unknown, field: string): number {
  if (typeof raw !== 'number' || !Number.isSafeInteger(raw) || raw < 0) {
    return gateModeProtocolDrift(`${field} must be a non-negative safe integer`)
  }
  return raw
}

function decodeSetGateModeResponse(raw: unknown, requestedMode: GateMode): SetGateModeResponse {
  if (!isRecord(raw)) return gateModeProtocolDrift('expected an object')
  const unknownField = Object.keys(raw).find(field => !SET_GATE_MODE_RESPONSE_FIELDS.has(field))
  if (unknownField) return gateModeProtocolDrift(`unknown field ${unknownField}`)
  if (raw.ok !== true) return gateModeProtocolDrift('ok must be true')

  const mode = normalizeGateModeValue(raw.mode)
  if (!mode) return gateModeProtocolDrift('mode is invalid')
  if (mode !== requestedMode) {
    return gateModeProtocolDrift(`mode does not match requested mode ${requestedMode}`)
  }

  const previousMode = raw.previous_mode === null
    ? null
    : normalizeGateModeValue(raw.previous_mode)
  if (previousMode === null && raw.previous_mode !== null) {
    return gateModeProtocolDrift('previous_mode must be null or a Gate mode')
  }

  const actor = typeof raw.actor === 'string' ? raw.actor.trim() : ''
  if (!actor) return gateModeProtocolDrift('actor must be a non-empty string')
  const changedAt = typeof raw.changed_at === 'string' ? raw.changed_at.trim() : ''
  if (!changedAt) return gateModeProtocolDrift('changed_at must be a non-empty string')

  const status = raw.recovery_status
  if (status !== 'completed' && status !== 'failed' && status !== 'not_requested') {
    return gateModeProtocolDrift('recovery_status is invalid')
  }
  const recoveryError = raw.recovery_error === null
    ? null
    : typeof raw.recovery_error === 'string' && raw.recovery_error.trim() !== ''
      ? raw.recovery_error
      : gateModeProtocolDrift('recovery_error must be null or a non-empty string')
  const reopened = nonNegativeSafeInteger(raw.reopened, 'reopened')
  const started = nonNegativeSafeInteger(raw.started, 'started')
  const queued = nonNegativeSafeInteger(raw.queued, 'queued')

  if (status === 'completed' && (mode !== 'auto_judge' || recoveryError !== null)) {
    return gateModeProtocolDrift('completed recovery requires auto_judge mode and no error')
  }
  if (status === 'failed'
      && (mode !== 'auto_judge' || recoveryError === null
        || reopened !== 0 || started !== 0 || queued !== 0)) {
    return gateModeProtocolDrift('failed recovery requires auto_judge mode, an error, and zero counts')
  }
  if (status === 'not_requested'
      && (mode === 'auto_judge' || recoveryError !== null
        || reopened !== 0 || started !== 0 || queued !== 0)) {
    return gateModeProtocolDrift('not_requested recovery requires a non-auto mode and zero outcome')
  }

  const replacedReadError = raw.replaced_read_error
  if (replacedReadError !== undefined
      && (typeof replacedReadError !== 'string' || replacedReadError.trim() === '')) {
    return gateModeProtocolDrift('replaced_read_error must be a non-empty string when present')
  }

  return {
    ok: true,
    mode,
    previous_mode: previousMode,
    actor,
    changed_at: changedAt,
    recovery_status: status,
    recovery_error: recoveryError,
    reopened,
    started,
    queued,
    ...(typeof replacedReadError === 'string'
      ? { replaced_read_error: replacedReadError }
      : {}),
  }
}

export async function setGateMode(mode: GateMode): Promise<SetGateModeResponse> {
  const raw = await post<unknown>('/api/v1/dashboard/gate/mode', { mode })
  return decodeSetGateModeResponse(raw, mode)
}
