// MASC Dashboard — Gate / HITL transport and normalization boundary.
// Public symbols are re-exported from dashboard.ts.

import { get, post, withRetries } from './core'
import { isRecord, asBoolean, asInt, asNullableString, asString } from '../components/common/normalize'
import { asNullableIsoTimestamp, normalizeKeeperApprovalQueueItem } from './board'
import { normalizeKeeperResolvedApprovalDecision } from '../lib/keeper-approval-decision'
import type {
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
    return {
      generated_at: asNullableIsoTimestamp(raw.generated_at) ?? undefined,
      note: typeof raw.note === 'string' && raw.note.trim() !== '' ? raw.note.trim() : undefined,
      approval_queue: approvalQueue,
      recent_resolved: recentResolved,
      hitl: normalizeHitlStatus(raw.hitl),
    }
  })
}

export function resolveGateApproval(
  id: string,
  decision: 'approve' | 'reject',
  reason?: string,
): Promise<{ ok: boolean; id: string; decision: 'approve' | 'reject' }> {
  return post('/api/v1/dashboard/gate/resolve', {
    id,
    decision,
    reason,
  })
}

export interface SetGateModeResponse {
  ok: boolean
  mode: GateMode
  previous_mode: GateMode | null
  actor: string
  changed_at: string
}

export function setGateMode(mode: GateMode): Promise<SetGateModeResponse> {
  return post('/api/v1/dashboard/gate/mode', { mode })
}
