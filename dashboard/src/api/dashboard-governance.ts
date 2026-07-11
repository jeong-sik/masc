// MASC Dashboard — Governance approvals / HITL / schedule / case fetchers.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, post, withRetries } from './core'
import { isRecord, asBoolean, asInt, asNullableString, asString } from '../components/common/normalize'
import {
  asNullableIsoTimestamp,
  normalizeGovernanceDecisionItem,
  normalizeGovernanceTimelineEvent,
  normalizeGovernanceJudgeSummary,
  normalizeGovernanceJudgment,
  normalizeKeeperApprovalQueueItem,
} from './board'
import { normalizePendingConfirmation } from '../pending-confirm'
import { asKeeperApprovalRiskLevel } from '../lib/governance-risk-level'
import { normalizeKeeperResolvedApprovalDecision } from '../lib/keeper-approval-decision'
import type {
  KeeperApprovalRule,
  DashboardGovernanceResponse,
  GovernanceDecisionItem,
  GovernanceTimelineEvent,
  GovernanceJudgment,
  KeeperApprovalQueueItem,
  KeeperResolvedApprovalItem,
  GovernanceCaseBundle,
  PendingConfirmation,
  ApprovalMode,
  HitlApprovalModeStatus,
} from '../types'
import type { AbortableRequestOptions } from './core'
import type { DashboardScheduledAutomationExecution } from './dashboard-tools-prompts'

export interface FetchDashboardGovernanceOptions extends AbortableRequestOptions {
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
    sandbox_profile: asNullableString(raw.sandbox_profile),
    backend: asNullableString(raw.backend),
    request_fingerprint: asNullableString(raw.request_fingerprint) ?? undefined,
    request_fingerprint_preview:
      asNullableString(raw.request_fingerprint_preview) ?? undefined,
    max_risk: asKeeperApprovalRiskLevel(raw.max_risk) ?? undefined,
    created_at: asNullableIsoTimestamp(raw.created_at_iso ?? raw.created_at),
    created_by: asNullableString(raw.created_by),
    last_matched_at:
      asNullableIsoTimestamp(raw.last_matched_at_iso ?? raw.last_matched_at),
    match_count: asInt(raw.match_count) ?? undefined,
    source_approval_id: asNullableString(raw.source_approval_id),
  }
}

// RFC-0319: normalize the operator approval mode. Any wire value other than the
// two known modes collapses to 'manual' — fail-closed, so a corrupt/unknown mode
// never renders as auto-approving. The band floor is enforced backend-side; this
// only governs how the toggle displays.
function normalizeApprovalMode(raw: unknown): HitlApprovalModeStatus | undefined {
  if (!isRecord(raw)) return undefined
  const mode: ApprovalMode = raw.mode === 'auto_low_risk' ? 'auto_low_risk' : 'manual'
  return {
    mode,
    auto_eligible_bands: Array.isArray(raw.auto_eligible_bands)
      ? raw.auto_eligible_bands.filter((value): value is string => typeof value === 'string')
      : [],
    fail_closed: asBoolean(raw.fail_closed) ?? false,
    read_error: asNullableString(raw.read_error) ?? undefined,
  }
}

function normalizeHitlStatus(raw: unknown): DashboardGovernanceResponse['hitl'] | undefined {
  if (!isRecord(raw)) return undefined
  return {
    enabled: asBoolean(raw.enabled) ?? false,
    disabled_by_env: asBoolean(raw.disabled_by_env) ?? false,
    env_name: asString(raw.env_name, 'MASC_DISABLE_HITL'),
    default_enabled: asBoolean(raw.default_enabled) ?? true,
    approval_mode: normalizeApprovalMode(raw.approval_mode),
  }
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
        matched_by: asNullableString(raw.rule_match.matched_by),
      }
    : null
  const decisionRaw = asNullableString(raw.decision)
  const decisionKind = asNullableString(raw.decision_kind)
  const decisionReason = asNullableString(raw.decision_reason)
  return {
    id,
    keeper_name: keeperName,
    tool_name: toolName,
    risk_level: asKeeperApprovalRiskLevel(raw.risk_level),
    decision: normalizeKeeperResolvedApprovalDecision(decisionKind),
    decision_raw: decisionRaw,
    decision_reason: decisionReason,
    resolved_at: asNullableIsoTimestamp(raw.resolved_at_iso ?? raw.resolved_at ?? raw.ts),
    turn_id: asInt(raw.turn_id),
    task_id: asNullableString(raw.task_id),
    goal_id: asNullableString(raw.goal_id),
    goal_ids: Array.isArray(raw.goal_ids)
      ? raw.goal_ids.filter((value): value is string => typeof value === 'string')
      : [],
    sandbox_target: asNullableString(raw.sandbox_target),
    disposition: asNullableString(raw.disposition),
    disposition_reason: asNullableString(raw.disposition_reason),
    rule_match: ruleMatch,
  }
}

export function fetchDashboardGovernance(
  opts?: FetchDashboardGovernanceOptions,
): Promise<DashboardGovernanceResponse> {
  return withRetries('fetchDashboardGovernance', async () => {
    const query = opts?.force ? '?force=1' : ''
    const raw = await get<Record<string, unknown>>(`/api/v1/dashboard/governance${query}`, {
      signal: opts?.signal,
    })
    const items = Array.isArray(raw.items)
      ? raw.items
          .map(item => normalizeGovernanceDecisionItem(item))
          .filter((item): item is GovernanceDecisionItem => item !== null)
      : []
    const pendingActions = Array.isArray(raw.pending_actions)
      ? raw.pending_actions
          .map(item => normalizePendingConfirmation(item))
          .filter((item): item is PendingConfirmation => item !== null)
      : []
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
      summary: isRecord(raw.summary)
        ? {
            cases_open: asInt(raw.summary.cases_open) ?? undefined,
            pending_ruling: asInt(raw.summary.pending_ruling) ?? undefined,
            ready_auto_execute: asInt(raw.summary.ready_auto_execute) ?? undefined,
            needs_human_gate: asInt(raw.summary.needs_human_gate) ?? undefined,
            executed: asInt(raw.summary.executed) ?? undefined,
            blocked: asInt(raw.summary.blocked) ?? undefined,
            ready_to_execute: asInt(raw.summary.ready_to_execute) ?? undefined,
            oldest_open_case_age_s:
              typeof raw.summary.oldest_open_case_age_s === 'number'
                ? raw.summary.oldest_open_case_age_s
                : null,
            last_activity_age_s:
              typeof raw.summary.last_activity_age_s === 'number'
                ? raw.summary.last_activity_age_s
                : null,
            judge_online:
              typeof raw.summary.judge_online === 'boolean'
                ? raw.summary.judge_online
                : undefined,
            judge_last_seen_at: asNullableIsoTimestamp(raw.summary.judge_last_seen_at),
          }
        : undefined,
      items,
      activity: Array.isArray(raw.activity)
        ? raw.activity
            .map(item => normalizeGovernanceTimelineEvent(item))
            .filter((item): item is GovernanceTimelineEvent => item !== null)
        : [],
      judge: normalizeGovernanceJudgeSummary(raw.judge),
      judgments: Array.isArray(raw.judgments)
        ? raw.judgments
            .map(item => normalizeGovernanceJudgment(item))
            .filter((item): item is GovernanceJudgment => item !== null)
        : [],
      pending_actions: pendingActions,
      approval_queue: approvalQueue,
      recent_resolved: recentResolved,
      approval_rules: approvalRules,
      hitl: normalizeHitlStatus(raw.hitl),
    }
  })
}

export function resolveGovernanceApproval(
  id: string,
  decision: 'approve' | 'reject',
  rememberRule?: boolean,
  reason?: string,
): Promise<{ ok: boolean; id: string; decision: 'approve' | 'reject'; rule_id?: string | null }> {
  return post('/api/v1/dashboard/governance/approvals/resolve', {
    id,
    decision,
    remember_rule: rememberRule,
    reason,
  })
}

export function deleteGovernanceApprovalRule(
  id: string,
): Promise<{ ok: boolean; id: string }> {
  return post('/api/v1/dashboard/governance/approvals/rules/delete', { id })
}

export interface SetApprovalModeResponse {
  ok: boolean
  mode: ApprovalMode
  previous_mode: ApprovalMode
  actor: string
  changed_at: string
}

// RFC-0319: set the operator approval mode. The backend rejects any value
// outside the closed union and enforces the separation-of-duties floor
// (critical/high never auto-approved) regardless of the mode set here.
export function setApprovalMode(mode: ApprovalMode): Promise<SetApprovalModeResponse> {
  return post('/api/v1/dashboard/governance/approval-mode', { mode })
}

export type DashboardScheduleDecision = 'approve' | 'reject'

export interface DashboardScheduleResolveResponse {
  ok: boolean
  schedule_id: string
  decision: DashboardScheduleDecision
  approved_by?: unknown
  schedule?: unknown
}

export function resolveScheduleApproval(
  scheduleId: string,
  decision: DashboardScheduleDecision,
  reason?: string,
): Promise<DashboardScheduleResolveResponse> {
  return post('/api/v1/dashboard/schedule/resolve', {
    schedule_id: scheduleId,
    decision,
    reason,
  })
}

export interface DashboardSchedulePruneResponse {
  ok: boolean
  pruned_count: number
}

export interface DashboardScheduleExecutionHistoryPage {
  schema: 'masc.dashboard.schedule_execution_history.v1'
  schedule_id: string
  rows: DashboardScheduledAutomationExecution[]
  total_count: number
  page_count: number
  next_cursor: string | null
}

export function fetchScheduleExecutionHistory(
  scheduleId: string,
  cursor?: string | null,
): Promise<DashboardScheduleExecutionHistoryPage> {
  const params = new URLSearchParams({ schedule_id: scheduleId })
  if (cursor) params.set('cursor', cursor)
  return get(`/api/v1/dashboard/schedule/executions?${params.toString()}`)
}

export function pruneSchedules(): Promise<DashboardSchedulePruneResponse> {
  return post('/api/v1/dashboard/schedule/prune', {})
}

export function fetchGovernanceCaseStatus(caseId: string): Promise<GovernanceCaseBundle> {
  return get(`/api/v1/governance/cases/${encodeURIComponent(caseId)}`)
}

function governanceCasesRetiredError(): Error {
  return new Error('Governance case write APIs are retired; use live judge and HITL approvals instead.')
}

export async function submitGovernancePetition(_title: string): Promise<{ case: { id: string } }> {
  throw governanceCasesRetiredError()
}

export async function submitGovernanceCaseBrief(
  _caseId: string,
  _stance: 'support' | 'oppose' | 'neutral',
  _summary: string,
): Promise<GovernanceCaseBundle> {
  throw governanceCasesRetiredError()
}

export async function decideGovernanceExecutionOrder(
  _caseId: string,
  _decision: 'confirm' | 'deny',
): Promise<void> {
  throw governanceCasesRetiredError()
}
