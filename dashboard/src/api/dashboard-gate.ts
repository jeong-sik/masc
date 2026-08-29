// MASC Dashboard — Gate / HITL transport and normalization boundary.
// Public symbols are re-exported from dashboard.ts.

import { ApiRequestError, get, post, runRequest } from './core'
import { isRecord, asBoolean, asInt, asNullableString, asString } from '../components/common/normalize'
import {
  asNullableIsoTimestamp,
  normalizeKeeperApprovalQueueItem,
  normalizeHitlSummaryStatus,
  normalizeKeeperExactAttempt,
} from './board'
import { normalizeKeeperResolvedApprovalDecision } from '../lib/keeper-approval-decision'
import { normalizeKeeperApprovalAuditReceipt } from '../lib/keeper-approval-audit'
import type {
  KeeperApprovalRule,
  DashboardGateResponse,
  KeeperApprovalQueueItem,
  KeeperApprovalQueueRowViolation,
  KeeperResolvedApprovalRowViolation,
  KeeperResolvedApprovalItem,
  KeeperResolvedApprovalPage,
  KeeperResolvedApprovalState,
  KeeperApprovalQueueState,
  KeeperApprovalRulesState,
  KeeperGateModeOverride,
  KeeperExactLanePreference,
  KeeperGateSettingsState,
  KeeperAutoJudgeRearmExpectation,
  GateDecisionSource,
  GateJudgeLane,
  GateMode,
  GateModeStatus,
  KeeperApprovalAuditReceipt,
} from '../types'
import type { AbortableRequestOptions } from './core'

export interface FetchDashboardGateOptions extends AbortableRequestOptions {
  force?: boolean
}

function gateSnapshotProtocolDrift(detail: string): never {
  throw new ApiRequestError({
    method: 'GET',
    path: '/api/v1/dashboard/gate',
    detail: `invalid Dashboard Gate response: ${detail}`,
    errorCode: 'protocol_drift',
  })
}

export function decodeKeeperApprovalQueueState(
  raw: unknown,
): Exclude<KeeperApprovalQueueState, { state: 'observation_error' }> | null {
  if (!isRecord(raw)) return null
  if (raw.state === 'ready' && Object.keys(raw).length === 1) {
    return { state: 'ready' }
  }
  if (
    raw.state === 'unavailable'
    && raw.code === 'reset_required'
    && typeof raw.title === 'string'
    && raw.title.trim() !== ''
    && typeof raw.operator_detail === 'string'
    && raw.operator_detail.trim() !== ''
    && raw.severity === 'bad'
    && raw.icon === '!'
    && Object.keys(raw).length === 6
  ) {
    return {
      state: 'unavailable',
      code: 'reset_required',
      title: raw.title.trim(),
      operator_detail: raw.operator_detail.trim(),
      severity: 'bad',
      icon: '!',
    }
  }
  return null
}

function normalizeApprovalQueueState(raw: unknown): KeeperApprovalQueueState {
  const state = decodeKeeperApprovalQueueState(raw)
  if (state) return state
  return gateSnapshotProtocolDrift('approval_queue_state is not a current closed variant')
}

function normalizeKeeperApprovalRule(raw: unknown): KeeperApprovalRule | null {
  if (!isRecord(raw)) return null
  const keys = Object.keys(raw).sort()
  const expectedKeys = [
    'created_at',
    'created_by',
    'expires_at',
    'id',
    'keeper_name',
    'request_fingerprint',
    'source_approval_id',
    'tool_name',
  ]
  if (keys.length !== expectedKeys.length || keys.some((key, index) => key !== expectedKeys[index])) {
    return null
  }
  const id = typeof raw.id === 'string' ? raw.id.trim() : ''
  const keeperName = typeof raw.keeper_name === 'string' ? raw.keeper_name.trim() : ''
  const toolName = typeof raw.tool_name === 'string' ? raw.tool_name.trim() : ''
  const requestFingerprint = typeof raw.request_fingerprint === 'string'
    ? raw.request_fingerprint
    : ''
  const createdAt = typeof raw.created_at === 'number' ? raw.created_at : Number.NaN
  const createdBy = typeof raw.created_by === 'string' && raw.created_by.trim() !== ''
    ? raw.created_by
    : undefined
  const sourceApprovalId =
    typeof raw.source_approval_id === 'string' && raw.source_approval_id.trim() !== ''
      ? raw.source_approval_id
      : undefined
  const expiresAt = raw.expires_at === null
    ? null
    : typeof raw.expires_at === 'number' && Number.isFinite(raw.expires_at)
      ? raw.expires_at
      : undefined
  if (
    !id
    || !keeperName
    || !toolName
    || !/^[a-f0-9]{64}$/.test(requestFingerprint)
    || !Number.isFinite(createdAt)
    || createdAt < 0
    || createdBy === undefined
    || sourceApprovalId === undefined
    || expiresAt === undefined
    || (expiresAt !== null && expiresAt <= createdAt)
  ) return null
  return {
    id,
    keeper_name: keeperName,
    tool_name: toolName,
    request_fingerprint: requestFingerprint,
    created_at: createdAt,
    created_by: createdBy,
    source_approval_id: sourceApprovalId,
    expires_at: expiresAt,
  }
}

function normalizeApprovalRulesState(raw: unknown): KeeperApprovalRulesState {
  if (!isRecord(raw)) return gateSnapshotProtocolDrift('approval_rules_state is not an object')
  if (raw.state === 'ready' && Object.keys(raw).length === 1) return { state: 'ready' }
  if (
    raw.state === 'unavailable'
    && typeof raw.error === 'string'
    && raw.error.trim() !== ''
    && Object.keys(raw).length === 2
  ) {
    return { state: 'unavailable', error: raw.error }
  }
  return gateSnapshotProtocolDrift('approval_rules_state is not a current closed variant')
}

/**
 * Same closed-variant shape as the approval-rules state, decoded separately so
 * a drift in one payload is reported against the field it came from.
 */
function normalizeKeeperSettingsState(raw: unknown, field: string): KeeperGateSettingsState {
  if (!isRecord(raw)) return gateSnapshotProtocolDrift(`${field} is not an object`)
  if (raw.state === 'ready' && Object.keys(raw).length === 1) return { state: 'ready' }
  if (
    raw.state === 'unavailable'
    && typeof raw.error === 'string'
    && raw.error.trim() !== ''
    && Object.keys(raw).length === 2
  ) {
    return { state: 'unavailable', error: raw.error }
  }
  return gateSnapshotProtocolDrift(`${field} is not a current closed variant`)
}

/**
 * Both per-Keeper rows carry the same four fields and differ only in the one
 * that says what was chosen, so they decode through one function.
 */
function normalizeKeeperSettingRow<K extends string>(
  raw: unknown,
  valueField: K,
  valueOf: (value: unknown) => string | null,
): ({ keeper_name: string; updated_by: string; updated_at: string } & Record<K, string>) | null {
  if (!isRecord(raw)) return null
  const expectedKeys = ['keeper_name', 'updated_at', 'updated_by', valueField].sort()
  const keys = Object.keys(raw).sort()
  if (keys.length !== expectedKeys.length || keys.some((key, index) => key !== expectedKeys[index])) {
    return null
  }
  const keeperName = typeof raw.keeper_name === 'string' ? raw.keeper_name.trim() : ''
  if (keeperName === '') return null
  const value = valueOf(raw[valueField])
  if (value === null) return null
  return {
    keeper_name: keeperName,
    updated_by: typeof raw.updated_by === 'string' ? raw.updated_by : '',
    updated_at: typeof raw.updated_at === 'string' ? raw.updated_at : '',
    [valueField]: value,
  } as { keeper_name: string; updated_by: string; updated_at: string } & Record<K, string>
}

function normalizeKeeperSettingRows<T>(
  raw: unknown,
  field: string,
  state: KeeperGateSettingsState,
  row: (item: unknown) => T | null,
): T[] {
  if (!Array.isArray(raw)) return gateSnapshotProtocolDrift(`${field} must be an array`)
  const rows = raw.map(row)
  if (rows.some(item => item === null)) {
    return gateSnapshotProtocolDrift(`${field} contains an invalid row`)
  }
  // Unavailable means the file could not be read, so there is nothing to have
  // parsed. Rows alongside that state would mean two sources disagreeing.
  if (state.state === 'unavailable' && rows.length !== 0) {
    return gateSnapshotProtocolDrift(`unavailable ${field} must be empty`)
  }
  return rows as T[]
}

function normalizeKeeperExactLanePreference(raw: unknown): KeeperExactLanePreference | null {
  if (!isRecord(raw)) return null
  if (!hasExactKeys(raw, ['keeper_name', 'lane_id', 'slot_id', 'updated_by', 'updated_at'])) {
    return null
  }
  const keeperName = typeof raw.keeper_name === 'string' ? raw.keeper_name.trim() : ''
  const laneId = typeof raw.lane_id === 'string' ? raw.lane_id.trim() : ''
  const slotId = typeof raw.slot_id === 'string' ? raw.slot_id.trim() : ''
  if (keeperName === '' || laneId === '' || slotId === '') return null
  return {
    keeper_name: keeperName,
    lane_id: laneId,
    slot_id: slotId,
    updated_by: typeof raw.updated_by === 'string' ? raw.updated_by : '',
    updated_at: typeof raw.updated_at === 'string' ? raw.updated_at : '',
  }
}

function normalizeGateModeValue(raw: unknown): GateMode | null {
  return raw === 'manual' || raw === 'auto_judge' || raw === 'always_allow' ? raw : null
}

function hasExactKeys(raw: Record<string, unknown>, expected: string[]): boolean {
  const keys = Object.keys(raw).sort()
  const sortedExpected = [...expected].sort()
  return keys.length === sortedExpected.length
    && keys.every((key, index) => key === sortedExpected[index])
}

function normalizeGateMode(label: string, raw: unknown): GateModeStatus {
  if (!isRecord(raw)) return gateSnapshotProtocolDrift(`${label} is not an object`)
  const mode = normalizeGateModeValue(raw.mode)
  if (!mode || typeof raw.configured !== 'boolean') {
    return gateSnapshotProtocolDrift(`${label} has an invalid mode or configured flag`)
  }
  if (raw.state === 'ready' && hasExactKeys(raw, ['mode', 'configured', 'state'])) {
    return { mode, configured: raw.configured, state: 'ready' }
  }
  if (
    mode === 'auto_judge'
    && raw.state === 'unavailable'
    && typeof raw.read_error === 'string'
    && raw.read_error.trim() !== ''
    && hasExactKeys(raw, ['mode', 'configured', 'state', 'read_error'])
  ) {
    return { mode, configured: raw.configured, state: 'unavailable', read_error: raw.read_error }
  }
  if (
    mode === 'manual'
    && raw.configured === true
    && raw.state === 'invalid'
    && typeof raw.read_error === 'string'
    && raw.read_error.trim() !== ''
    && hasExactKeys(raw, ['mode', 'configured', 'state', 'read_error'])
  ) {
    return { mode, configured: true, state: 'invalid', read_error: raw.read_error }
  }
  return gateSnapshotProtocolDrift(`${label} is not a current closed variant`)
}

function normalizeGateJudgeLane(raw: unknown): GateJudgeLane {
  if (!isRecord(raw)) return gateSnapshotProtocolDrift('hitl.judge_lane is not an object')
  const laneId = asString(raw.lane_id, '').trim()
  if (!laneId) return gateSnapshotProtocolDrift('hitl.judge_lane.lane_id is invalid')
  if (
    raw.status === 'available'
    && Array.isArray(raw.slots)
    && hasExactKeys(raw, ['status', 'lane_id', 'slots'])
  ) {
    const slots = raw.slots.filter(
      (slot): slot is string => typeof slot === 'string' && slot.trim() !== '',
    )
    if (slots.length === 0 || slots.length !== raw.slots.length) {
      return gateSnapshotProtocolDrift('hitl.judge_lane.slots is invalid')
    }
    return { status: 'available', lane_id: laneId, slots }
  }
  if (raw.status === 'unavailable' && hasExactKeys(raw, ['status', 'lane_id', 'reason'])) {
    const reason = asString(raw.reason, '').trim()
    if (reason) return { status: 'unavailable', lane_id: laneId, reason }
  }
  return gateSnapshotProtocolDrift('hitl.judge_lane is not a current closed variant')
}

function normalizeHitlStatus(raw: unknown): DashboardGateResponse['hitl'] {
  if (
    !isRecord(raw)
    || !hasExactKeys(raw, ['gate_mode', 'external_gate_mode', 'judge_lane'])
  ) {
    return gateSnapshotProtocolDrift('hitl is not the current exact object')
  }
  return {
    gate_mode: normalizeGateMode('hitl.gate_mode', raw.gate_mode),
    external_gate_mode: normalizeGateMode(
      'hitl.external_gate_mode',
      raw.external_gate_mode,
    ),
    judge_lane: normalizeGateJudgeLane(raw.judge_lane),
  }
}

function normalizeGateDecisionSource(raw: unknown): GateDecisionSource | null {
  return raw === 'always_allowed' || raw === 'auto_judge' || raw === 'human_operator'
    ? raw
    : null
}

/** Decode one resolved-history row.  Every field below carries its own
 *  validity check, so a missing key is already rejected here; an exact-key
 *  gate would add only "reject a key I do not know yet", which on a
 *  read-only projection turns a rolling deploy into a blank Gate (#31695). */
function normalizeKeeperResolvedApprovalItem(raw: unknown): KeeperResolvedApprovalItem | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id, '').trim()
  const keeperName = asString(raw.keeper_name, '').trim()
  const toolName = asString(raw.tool_name, '').trim()
  const decisionRaw = typeof raw.decision === 'string' ? raw.decision.trim() : ''
  const decision = normalizeKeeperResolvedApprovalDecision(
    typeof raw.decision_kind === 'string' ? raw.decision_kind : null,
  )
  const decisionReason = raw.decision_reason === null
    ? null
    : typeof raw.decision_reason === 'string' && raw.decision_reason.trim() !== ''
      ? raw.decision_reason.trim()
      : undefined
  const resolvedAt = asNullableIsoTimestamp(raw.resolved_at)
  const turnId = raw.turn_id === null ? null : asInt(raw.turn_id)
  const taskId = raw.task_id === null ? null : asNullableString(raw.task_id)
  const goalId = raw.goal_id === null ? null : asNullableString(raw.goal_id)
  const actor = raw.actor === null
    ? null
    : typeof raw.actor === 'string' && raw.actor.trim() !== ''
      ? raw.actor.trim()
      : undefined
  const decisionSource = normalizeGateDecisionSource(raw.decision_source)
  const summaryStatus = normalizeHitlSummaryStatus(raw.summary_status)
  const exactAttempt = normalizeKeeperExactAttempt(raw.exact_attempt)
  if (
    raw.event !== 'resolved'
    || !id
    || !keeperName
    || !toolName
    || !decisionRaw
    || !decision
    || decisionReason === undefined
    || (decision === 'approve' && decisionReason !== null)
    || (decision === 'reject' && decisionReason === null)
    || resolvedAt === null
    || (turnId !== null && (turnId === undefined || turnId < 0))
    || (taskId !== null && !taskId)
    || (goalId !== null && !goalId)
    || actor === undefined
    || !decisionSource
    || summaryStatus === null
    || exactAttempt === null
  ) return null
  return {
    id,
    keeper_name: keeperName,
    tool_name: toolName,
    decision,
    decision_raw: decisionRaw,
    decision_reason: decisionReason,
    resolved_at: resolvedAt,
    turn_id: turnId,
    task_id: taskId,
    goal_id: goalId,
    actor,
    decision_source: decisionSource,
    summary_status: summaryStatus,
    exact_attempt: exactAttempt,
  }
}

/** Decode the exact page bounds that make resolved-history completeness explicit. */
function normalizeKeeperResolvedApprovalPage(
  raw: unknown,
): KeeperResolvedApprovalPage | null {
  if (!isRecord(raw)) return null
  const returned = asInt(raw.returned)
  const matched = asInt(raw.matched)
  const limit = asInt(raw.limit)
  const windowMinutes = asInt(raw.window_minutes)
  const truncated = asBoolean(raw.truncated)
  const scanExhausted = asBoolean(raw.scan_exhausted)
  if (
    returned === undefined
    || matched === undefined
    || limit === undefined
    || windowMinutes === undefined
    || truncated === undefined
    || scanExhausted === undefined
  ) {
    return null
  }
  if (returned < 0 || matched < 0 || limit < 0 || windowMinutes <= 0) return null
  return {
    returned,
    matched,
    limit,
    window_minutes: windowMinutes,
    truncated,
    scan_exhausted: scanExhausted,
  }
}

function normalizeKeeperResolvedApprovalState(raw: unknown): KeeperResolvedApprovalState {
  if (!isRecord(raw)) return gateSnapshotProtocolDrift('recent_resolved_state is not an object')
  if (raw.state === 'ready' && hasExactKeys(raw, ['state'])) return { state: 'ready' }
  if (
    raw.state === 'unavailable'
    && raw.stage === 'list_recent_resolved'
    && typeof raw.error === 'string'
    && raw.error.trim() !== ''
    && hasExactKeys(raw, ['state', 'stage', 'error'])
  ) {
    return { state: 'unavailable', stage: raw.stage, error: raw.error.trim() }
  }
  return gateSnapshotProtocolDrift('recent_resolved_state is not a current closed variant')
}

export function fetchDashboardGate(
  opts?: FetchDashboardGateOptions,
): Promise<DashboardGateResponse> {
  return runRequest('fetchDashboardGate', async () => {
    const query = opts?.force ? '?force=1' : ''
    const raw = await get<Record<string, unknown>>(`/api/v1/dashboard/gate${query}`, {
      signal: opts?.signal,
    })
    const approvalQueueState = normalizeApprovalQueueState(raw.approval_queue_state)
    let approvalQueue: KeeperApprovalQueueItem[] | null
    const approvalQueueViolations: KeeperApprovalQueueRowViolation[] = []
    const recentResolvedViolations: KeeperResolvedApprovalRowViolation[] = []
    if (approvalQueueState.state === 'unavailable') {
      if (raw.approval_queue !== null) {
        return gateSnapshotProtocolDrift('unavailable approval_queue must be null')
      }
      approvalQueue = null
    } else {
      if (!Array.isArray(raw.approval_queue)) {
        return gateSnapshotProtocolDrift('ready approval_queue must be an array')
      }
      // Preserve the exact valid rows and expose every invalid row as a typed
      // violation with the identity fields that can be decoded safely.
      const accepted: KeeperApprovalQueueItem[] = []
      raw.approval_queue.forEach((item, index) => {
        const normalized = normalizeKeeperApprovalQueueItem(item)
        if (normalized !== null) {
          accepted.push(normalized)
          return
        }
        const record = isRecord(item) ? item : undefined
        approvalQueueViolations.push({
          index,
          id: record ? asNullableString(record.id) : null,
          keeper_name: record ? asNullableString(record.keeper_name) : null,
          tool_name: record ? asNullableString(record.tool_name) : null,
        })
      })
      approvalQueue = accepted
    }
    const recentResolvedState = normalizeKeeperResolvedApprovalState(raw.recent_resolved_state)
    let recentResolved: KeeperResolvedApprovalItem[] | null
    let recentResolvedPage: KeeperResolvedApprovalPage | null
    if (recentResolvedState.state === 'unavailable') {
      if (raw.recent_resolved !== null || raw.recent_resolved_page !== null) {
        return gateSnapshotProtocolDrift('unavailable resolved history must use null rows and page')
      }
      recentResolved = null
      recentResolvedPage = null
    } else {
      if (!Array.isArray(raw.recent_resolved)) {
        return gateSnapshotProtocolDrift('ready recent_resolved must be an array')
      }
      // Preserve the exact valid rows and expose every invalid row as a typed
      // violation, the way approval_queue already does (#26094).  One
      // undecodable history row must not blind the operator to the open-Gate
      // count (#31695).
      const accepted: KeeperResolvedApprovalItem[] = []
      const sentRowCount = raw.recent_resolved.length
      raw.recent_resolved.forEach((item, index) => {
        const normalized = normalizeKeeperResolvedApprovalItem(item)
        if (normalized !== null) {
          accepted.push(normalized)
          return
        }
        const record = isRecord(item) ? item : undefined
        recentResolvedViolations.push({
          index,
          id: record ? asNullableString(record.id) : null,
          keeper_name: record ? asNullableString(record.keeper_name) : null,
          tool_name: record ? asNullableString(record.tool_name) : null,
        })
      })
      recentResolved = accepted
      recentResolvedPage = normalizeKeeperResolvedApprovalPage(raw.recent_resolved_page)
      if (recentResolvedPage === null) {
        return gateSnapshotProtocolDrift('ready recent_resolved_page is invalid')
      }
      // [returned] is the server's count of rows it emitted, so it is compared
      // against what arrived — not against what this client could decode.
      if (recentResolvedPage.returned !== sentRowCount) {
        return gateSnapshotProtocolDrift('recent_resolved_page.returned does not match row count')
      }
    }
    const approvalRulesState = normalizeApprovalRulesState(raw.approval_rules_state)
    if (!Array.isArray(raw.approval_rules)) {
      return gateSnapshotProtocolDrift('approval_rules must be an array')
    }
    const approvalRules = raw.approval_rules.map(item => normalizeKeeperApprovalRule(item))
    if (approvalRules.some(rule => rule === null)) {
      return gateSnapshotProtocolDrift('approval_rules contains an invalid rule')
    }
    if (approvalRulesState.state === 'unavailable' && approvalRules.length !== 0) {
      return gateSnapshotProtocolDrift('unavailable approval_rules must be empty')
    }
    const keeperModesState = normalizeKeeperSettingsState(raw.keeper_modes_state, 'keeper_modes_state')
    const keeperModes = normalizeKeeperSettingRows<KeeperGateModeOverride>(
      raw.keeper_modes,
      'keeper_modes',
      keeperModesState,
      item => normalizeKeeperSettingRow(item, 'mode', normalizeGateModeValue) as KeeperGateModeOverride | null,
    )
    const keeperExactLanesState = normalizeKeeperSettingsState(
      raw.keeper_exact_lanes_state,
      'keeper_exact_lanes_state',
    )
    const keeperExactLanes = normalizeKeeperSettingRows<KeeperExactLanePreference>(
      raw.keeper_exact_lanes,
      'keeper_exact_lanes',
      keeperExactLanesState,
      normalizeKeeperExactLanePreference,
    )
    return {
      generated_at: asNullableIsoTimestamp(raw.generated_at) ?? undefined,
      note: typeof raw.note === 'string' && raw.note.trim() !== '' ? raw.note.trim() : undefined,
      approval_queue: approvalQueue,
      approval_queue_state: approvalQueueState,
      approval_queue_violations: approvalQueueViolations,
      recent_resolved_violations: recentResolvedViolations,
      recent_resolved: recentResolved,
      recent_resolved_page: recentResolvedPage,
      recent_resolved_state: recentResolvedState,
      approval_rules: approvalRules as KeeperApprovalRule[],
      approval_rules_state: approvalRulesState,
      keeper_modes: keeperModes,
      keeper_modes_state: keeperModesState,
      keeper_exact_lanes: keeperExactLanes,
      keeper_exact_lanes_state: keeperExactLanesState,
      hitl: normalizeHitlStatus(raw.hitl),
    }
  })
}

export type GateApprovalResolution =
  | { decision: 'approve'; rememberRule: boolean; ruleExpiresAt?: number }
  | { decision: 'reject'; reason: string }

export interface ResolveGateApprovalResponse {
  ok: true
  id: string
  decision: 'approve' | 'reject'
  rule_id: string | null
  audit_receipts: KeeperApprovalAuditReceipt[]
}

export interface DeleteGateApprovalRuleResponse {
  ok: true
  id: string
  audit: KeeperApprovalAuditReceipt
}

function gateMutationProtocolDrift(path: string, detail: string): never {
  throw new ApiRequestError({
    method: 'POST',
    path,
    detail: `invalid Gate mutation response: ${detail}`,
    errorCode: 'protocol_drift',
  })
}

function decodeResolveGateApprovalResponse(
  raw: unknown,
  requestedId: string,
  requestedDecision: 'approve' | 'reject',
): ResolveGateApprovalResponse {
  const path = '/api/v1/dashboard/gate/resolve'
  if (!isRecord(raw) || !hasExactKeys(raw, [
    'ok',
    'id',
    'decision',
    'rule_id',
    'audit_receipts',
  ])) return gateMutationProtocolDrift(path, 'fields must be exact')
  if (raw.ok !== true || raw.id !== requestedId || raw.decision !== requestedDecision) {
    return gateMutationProtocolDrift(path, 'committed identity does not match the request')
  }
  const ruleId = raw.rule_id === null
    ? null
    : typeof raw.rule_id === 'string' && raw.rule_id.trim() !== ''
      ? raw.rule_id
      : gateMutationProtocolDrift(path, 'rule_id must be null or non-blank')
  if (!Array.isArray(raw.audit_receipts)) {
    return gateMutationProtocolDrift(path, 'audit_receipts must be an array')
  }
  const auditReceipts = raw.audit_receipts.map(normalizeKeeperApprovalAuditReceipt)
  if (auditReceipts.some(receipt => receipt === null)) {
    return gateMutationProtocolDrift(path, 'audit_receipts contains an invalid receipt')
  }
  const actualEvents = (auditReceipts as KeeperApprovalAuditReceipt[])
    .map(receipt => receipt.event)
  const isResolutionOnly = actualEvents.length === 1 && actualEvents[0] === 'resolved'
  const isRuleCreationAndResolution = ruleId !== null
    && actualEvents.length === 2
    && actualEvents[0] === 'rule_created'
    && actualEvents[1] === 'resolved'
  if (!isResolutionOnly && !isRuleCreationAndResolution) {
    return gateMutationProtocolDrift(path, 'audit_receipts do not match the committed mutation')
  }
  return {
    ok: true,
    id: requestedId,
    decision: requestedDecision,
    rule_id: ruleId,
    audit_receipts: auditReceipts as KeeperApprovalAuditReceipt[],
  }
}

function decodeDeleteGateApprovalRuleResponse(
  raw: unknown,
  requestedId: string,
): DeleteGateApprovalRuleResponse {
  const path = '/api/v1/dashboard/gate/rules/delete'
  if (!isRecord(raw) || !hasExactKeys(raw, ['ok', 'id', 'audit'])) {
    return gateMutationProtocolDrift(path, 'fields must be exact')
  }
  const audit = normalizeKeeperApprovalAuditReceipt(raw.audit)
  if (
    raw.ok !== true
    || raw.id !== requestedId
    || audit === null
    || audit.event !== 'rule_deleted'
  ) {
    return gateMutationProtocolDrift(path, 'committed identity or audit receipt is invalid')
  }
  return { ok: true, id: raw.id, audit }
}

export async function resolveGateApproval(
  id: string,
  resolution: GateApprovalResolution,
): Promise<ResolveGateApprovalResponse> {
  const raw = await post<unknown>('/api/v1/dashboard/gate/resolve', {
    id,
    decision: resolution.decision,
    remember_rule: resolution.decision === 'approve' ? resolution.rememberRule : false,
    reason: resolution.decision === 'reject' ? resolution.reason : undefined,
    rule_expires_at: resolution.decision === 'approve' ? resolution.ruleExpiresAt : undefined,
  })
  return decodeResolveGateApprovalResponse(raw, id, resolution.decision)
}

export function retryGateAutoJudge(
  id: string,
  expected: KeeperAutoJudgeRearmExpectation,
): Promise<{ ok: boolean; id: string }> {
  return post('/api/v1/dashboard/gate/retry', { id, ...expected })
}

export async function deleteGateApprovalRule(
  id: string,
): Promise<DeleteGateApprovalRuleResponse> {
  const raw = await post<unknown>('/api/v1/dashboard/gate/rules/delete', { id })
  return decodeDeleteGateApprovalRuleResponse(raw, id)
}

export interface SetGateModeResponse {
  ok: boolean
  mode: GateMode
  previous_mode: GateMode | null
  actor: string
  changed_at: string
  recovery_status: 'completed' | 'partial' | 'failed' | 'not_requested'
  recovery_error: string | null
  started: number
  queued: number
  recovery_failure_count: number
  recovery_failures: GateModeRecoveryFailure[]
  replaced_read_error?: string
}

export interface GateModeRecoveryFailure {
  keeper_name: string
  approval_id: string | null
  operator_detail: string
}

const SET_GATE_MODE_RESPONSE_FIELDS = new Set([
  'ok',
  'mode',
  'previous_mode',
  'actor',
  'changed_at',
  'recovery_status',
  'recovery_error',
  'started',
  'queued',
  'recovery_failure_count',
  'recovery_failures',
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
  if (
    status !== 'completed'
    && status !== 'partial'
    && status !== 'failed'
    && status !== 'not_requested'
  ) {
    return gateModeProtocolDrift('recovery_status is invalid')
  }
  const recoveryError = raw.recovery_error === null
    ? null
    : typeof raw.recovery_error === 'string' && raw.recovery_error.trim() !== ''
      ? raw.recovery_error
      : gateModeProtocolDrift('recovery_error must be null or a non-empty string')
  const started = nonNegativeSafeInteger(raw.started, 'started')
  const queued = nonNegativeSafeInteger(raw.queued, 'queued')
  const recoveryFailureCount =
    nonNegativeSafeInteger(raw.recovery_failure_count, 'recovery_failure_count')
  if (!Array.isArray(raw.recovery_failures)) {
    return gateModeProtocolDrift('recovery_failures must be an array')
  }
  const recoveryFailures = raw.recovery_failures.map((failure, index) => {
    if (!isRecord(failure)) {
      return gateModeProtocolDrift(`recovery_failures[${index}] must be an object`)
    }
    const fields = Object.keys(failure)
    if (
      fields.length !== 3
      || !fields.includes('keeper_name')
      || !fields.includes('approval_id')
      || !fields.includes('operator_detail')
    ) {
      return gateModeProtocolDrift(
        `recovery_failures[${index}] fields must be exact`,
      )
    }
    const keeperName =
      typeof failure.keeper_name === 'string' ? failure.keeper_name.trim() : ''
    const approvalId =
      failure.approval_id === null
        ? null
        : typeof failure.approval_id === 'string' && failure.approval_id.trim() !== ''
          ? failure.approval_id
          : gateModeProtocolDrift(
              `recovery_failures[${index}].approval_id must be null or non-empty`,
            )
    const operatorDetail =
      typeof failure.operator_detail === 'string'
        ? failure.operator_detail.trim()
        : ''
    if (!keeperName || !operatorDetail) {
      return gateModeProtocolDrift(
        `recovery_failures[${index}] strings must be non-empty`,
      )
    }
    return {
      keeper_name: keeperName,
      approval_id: approvalId,
      operator_detail: operatorDetail,
    }
  })
  if (recoveryFailures.length !== recoveryFailureCount) {
    return gateModeProtocolDrift(
      'recovery_failure_count must equal recovery_failures length',
    )
  }

  if (
    status === 'completed'
    && (mode !== 'auto_judge' || recoveryError !== null || recoveryFailureCount !== 0)
  ) {
    return gateModeProtocolDrift(
      'completed recovery requires auto_judge mode and no owner failures',
    )
  }
  if (
    status === 'partial'
    && (mode !== 'auto_judge' || recoveryError !== null || recoveryFailureCount === 0)
  ) {
    return gateModeProtocolDrift(
      'partial recovery requires auto_judge mode and owner failures',
    )
  }
  if (status === 'failed'
      && (mode !== 'auto_judge' || recoveryError === null
        || started !== 0 || queued !== 0 || recoveryFailureCount !== 0)) {
    return gateModeProtocolDrift(
      'failed recovery requires auto_judge mode, an error, and zero outcomes',
    )
  }
  if (status === 'not_requested'
      && (mode === 'auto_judge' || recoveryError !== null
        || started !== 0 || queued !== 0 || recoveryFailureCount !== 0)) {
    return gateModeProtocolDrift(
      'not_requested recovery requires a non-auto mode and zero outcomes',
    )
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
    started,
    queued,
    recovery_failure_count: recoveryFailureCount,
    recovery_failures: recoveryFailures,
    ...(typeof replacedReadError === 'string'
      ? { replaced_read_error: replacedReadError }
      : {}),
  }
}

export async function setGateMode(mode: GateMode): Promise<SetGateModeResponse> {
  const raw = await post<unknown>('/api/v1/dashboard/gate/mode', { mode })
  return decodeSetGateModeResponse(raw, mode)
}

/** The external-services lane. Same request and response contract as
 *  `setGateMode`; a different switch on the server, so opening the workspace
 *  lane never opens writes into an attached outside service. */
export async function setExternalGateMode(mode: GateMode): Promise<SetGateModeResponse> {
  const raw = await post<unknown>('/api/v1/dashboard/gate/external-mode', { mode })
  return decodeSetGateModeResponse(raw, mode)
}
