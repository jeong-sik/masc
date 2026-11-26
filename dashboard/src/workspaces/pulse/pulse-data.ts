/**
 * Pulse Workspace — Epoch-fenced, ResourceCache-backed data loaders.
 *
 * Respects all 3 wire envelopes from #36:
 * - V2Envelope (`apiGetV2`): `/api/v1/memory/world`, `/api/v1/candle/ledger`
 * - Flat JSON (`apiGet`): `/api/v1/dashboard/shell`, `/api/v1/gate/keepers`,
 *   `/api/v1/dashboard/keeper-costs`, `/api/v1/dashboard/provider-usage-history`,
 *   `/api/v1/keepers/tool-approvals`, `/api/v1/keepers/asks`,
 *   `/api/v1/dashboard/goals`, `/api/v1/dashboard/board`
 */

import { ok, type Result } from '../../lib/result'
import { authSession } from '../../core/auth'
import { apiGet, apiGetV2, type ApiError } from '../../core/transport'
import { decodeToolApprovalsWire, isOpenKeeperAskRow } from '../../api/hitl-decoders'
import { GoalSourceUnavailableError, goalSourceUnavailable } from '../../api/dashboard-goals'
import { decodeKeeperApprovalQueueState } from '../../lib/gate-observation-state'
import { decodeKeeperLaneFailures, decodeKeeperPathRest } from '../../api/keeper-diagnostics'
import { observedAbsent, resourceCache, type FetchReason, type Observed } from '../../core/resource-cache'
import { timeWindowProviderDays, type TimeWindow } from '../../core/time-window'
import type {
  PulseApprovalItem,
  PulseAskItem,
  PulseBoardPost,
  PulseCandleDigest,
  PulseGoalSummary,
  PulseGoalsSnapshot,
  PulseKeeperCostRow,
  PulseKeeperLaneFailure,
  PulseKeeperPathRest,
  PulseKeeperRow,
  PulseProviderUsagePoint,
  PulseProviderUsageSnapshot,
  PulseReportedNoWindows,
  PulseShellGroup,
  PulseShellSnapshot,
  PulseTurnSlot,
  PulseUsageUtilization,
  PulseWorldMemoryDigest,
} from './types'

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function asStr(v: unknown): string | null {
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : null
}

function asNum(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

function decodeShell(raw: unknown): PulseShellSnapshot {
  const rec = isRecord(raw) ? raw : {}
  const counts = isRecord(rec.counts) ? rec.counts : {}
  const scorecard = isRecord(rec.scorecard_24h) ? rec.scorecard_24h : {}
  const status = isRecord(rec.status) ? rec.status : {}
  const rawGroups = Array.isArray(rec.groups) ? rec.groups : []

  const groups: PulseShellGroup[] = []
  for (const g of rawGroups) {
    if (!isRecord(g)) continue
    const group = asStr(g.group)
    if (!group) continue
    const keepers = Array.isArray(g.keepers)
      ? g.keepers.filter((x): x is string => typeof x === 'string' && x.trim().length > 0)
      : []
    groups.push({
      group,
      keeper_count: asNum(g.keeper_count) ?? keepers.length,
      keepers,
    })
  }

  return {
    generated_at: asStr(rec.generated_at),
    project: asStr(status.project) ?? asStr(rec.project),
    version: asStr(status.version) ?? asStr(rec.version),
    counts: {
      agents: asNum(counts.agents),
      tasks: asNum(counts.tasks),
      tasks_done_24h: asNum(counts.tasks_done_24h),
      keepers: asNum(counts.keepers),
      configured_keepers: asNum(rec.configured_keepers) ?? asNum(counts.configured_keepers),
      total_runtimes: asNum(counts.total_runtimes),
    },
    scorecard: {
      tasks_done_24h: asNum(scorecard.tasks_done_24h),
      tasks_awaiting_verification: asNum(scorecard.tasks_awaiting_verification),
      tasks_in_progress: asNum(scorecard.tasks_in_progress),
      turns_24h: asNum(scorecard.turns_24h),
      cost_24h_usd: asNum(scorecard.cost_24h_usd),
      verifications_passed_24h: asNum(scorecard.verifications_passed_24h),
      verifications_rejected_24h: asNum(scorecard.verifications_rejected_24h),
      goals_completed_24h: asNum(scorecard.goals_completed_24h),
    },
    groups,
  }
}

function decodeTurnSlots(raw: unknown): { known_since: number; slots: PulseTurnSlot[] } | null {
  if (!isRecord(raw) || !Array.isArray(raw.slots)) return null
  const knownSince = asNum(raw.known_since) ?? 0
  const slots: PulseTurnSlot[] = []
  for (const s of raw.slots) {
    if (!isRecord(s)) continue
    const startsAt = asNum(s.starts_at)
    if (startsAt === null) continue
    slots.push({
      starts_at: startsAt,
      ok: asNum(s.ok) ?? 0,
      rested: asNum(s.rested) ?? 0,
      failed: asNum(s.failed) ?? 0,
      scheduled: asNum(s.scheduled) ?? 0,
      reacted: asNum(s.reacted) ?? 0,
      chat: asNum(s.chat) ?? 0,
      own: asNum(s.own) ?? 0,
      unknown: asNum(s.unknown) ?? 0,
    })
  }
  return { known_since: knownSince, slots }
}

function decodePulsePathRest(raw: unknown): PulseKeeperPathRest | null {
  return decodeKeeperPathRest(raw)
}

function decodePulseLaneFailures(raw: unknown): readonly PulseKeeperLaneFailure[] {
  return decodeKeeperLaneFailures(raw)
}

export function decodePulseKeepers(raw: unknown): PulseKeeperRow[] {
  const rec = isRecord(raw) ? raw : {}
  const list = Array.isArray(rec.keepers) ? rec.keepers : []
  const rows: PulseKeeperRow[] = []

  for (const item of list) {
    if (!isRecord(item)) continue
    const name = asStr(item.name)
    if (!name) continue
    const meta = isRecord(item.meta) ? item.meta : null
    const issue = isRecord(item.effective_meta_error) ? asStr(item.effective_meta_error.message) : null
    const lastFailureRaw = isRecord(item.last_failure) ? item.last_failure : null
    const lastFailure = lastFailureRaw && asStr(lastFailureRaw.cause)
      ? { cause: asStr(lastFailureRaw.cause)!, at_unix: asNum(lastFailureRaw.at_unix) }
      : null
    const candleVal = typeof item.candle_balance_milli === 'string' || typeof item.candle_balance_milli === 'number'
      ? item.candle_balance_milli
      : null
    const ctxProvRaw = asStr(item.context_provenance)
    const contextProvenance = ctxProvRaw === 'measured' || ctxProvRaw === 'estimated' || ctxProvRaw === 'unavailable'
      ? ctxProvRaw
      : null

    rows.push({
      name,
      status: asStr(item.status) ?? 'unknown',
      phase: asStr(item.phase) ?? (issue ? 'error' : 'idle'),
      health: asStr(item.health) ?? (issue ? 'failing' : 'unknown'),
      paused: item.paused === true,
      keepalive_running: item.keepalive_running === true,
      runtime_id: asStr(item.runtime_id) ?? 'unassigned',
      sandbox_profile: meta ? asStr(meta.sandbox_profile) : null,
      context_ratio: asNum(item.context_ratio),
      context_tokens: asNum(item.context_tokens),
      context_max: asNum(item.context_max),
      context_provenance: contextProvenance,
      estimated_context_ratio: asNum(item.estimated_context_ratio),
      context_unavailable_reason: asStr(item.context_metrics_unavailable_reason),
      next_action: asStr(item.next_action),
      runtime_blocker_summary: asStr(item.runtime_blocker_summary),
      runtime_blocker_signature: asStr(item.runtime_blocker_signature),
      runtime_blocker_class: asStr(item.runtime_blocker_class),
      runtime_path_rest: decodePulsePathRest(item.runtime_path_rest),
      operator_disposition: asStr(item.operator_disposition),
      operator_disposition_reason: asStr(item.operator_disposition_reason),
      failing_since: asNum(item.failing_since),
      runtime_lane_failures: decodePulseLaneFailures(item.runtime_lane_observation),
      last_failure: lastFailure,
      recent_turns: decodeTurnSlots(item.recent_turns),
      candle_balance_milli: candleVal,
      directory_issue: issue,
    })
  }
  return rows
}

function decodeCosts(raw: unknown): PulseKeeperCostRow[] {
  const rec = isRecord(raw) ? raw : {}
  const list = Array.isArray(rec.keepers) ? rec.keepers : []
  const out: PulseKeeperCostRow[] = []
  for (const item of list) {
    if (!isRecord(item)) continue
    const name = asStr(item.keeper_name)
    if (!name) continue
    out.push({
      keeper_name: name,
      total_cost_usd: asNum(item.total_cost_usd),
      cost_reported_samples: asNum(item.cost_reported_samples) ?? 0,
      cost_unreported_samples: asNum(item.cost_unreported_samples) ?? 0,
      total_tokens: asNum(item.total_tokens),
      sample_count: asNum(item.sample_count) ?? 0,
    })
  }
  return out
}

function decodeUsageUtilization(pt: Record<string, unknown>): PulseUsageUtilization | null {
  switch (pt.unit) {
    case 'fraction': {
      const value = asNum(pt.value)
      return value === null ? null : { unit: 'fraction', value }
    }
    case 'percent': {
      const value = asNum(pt.value)
      return value === null ? null : { unit: 'percent', value }
    }
    case 'usd': {
      const value = asNum(pt.value)
      if (value === null) return null
      if (pt.limit !== null && pt.limit !== undefined && asNum(pt.limit) === null) return null
      return { unit: 'usd', value, limit: asNum(pt.limit) }
    }
    case 'credit_balance': {
      const remaining = asNum(pt.remaining)
      return remaining === null ? null : { unit: 'credit_balance', remaining }
    }
    case 'credit_unlimited':
      return { unit: 'credit_unlimited' }
    default:
      return null
  }
}

function decodeProviderUsagePoint(pt: unknown): PulseProviderUsagePoint | null {
  if (!isRecord(pt)) return null
  const scopeId = asStr(pt.scope_id)
  const source = asStr(pt.source)
  const kind = asStr(pt.kind)
  const observedAt = asNum(pt.observed_at)
  const utilization = decodeUsageUtilization(pt)
  if (!scopeId || !source || !kind || observedAt === null || !utilization) return null
  // `resets_at` is optional on the wire; a present non-number is a broken row,
  // not an unknown reset.
  if (pt.resets_at !== null && pt.resets_at !== undefined && asNum(pt.resets_at) === null) return null
  return {
    scope_id: scopeId,
    source,
    kind,
    limit_id: asStr(pt.limit_id),
    observed_at: observedAt,
    resets_at: asNum(pt.resets_at),
    utilization,
  }
}

export function decodeProviderUsage(raw: unknown): PulseProviderUsageSnapshot {
  if (!isRecord(raw)) return { state: 'unavailable', reason: 'invalid_provider_usage' }
  if (raw.state === 'unavailable') {
    return { state: 'unavailable', reason: asStr(raw.reason) ?? 'provider usage unavailable' }
  }
  if (!Array.isArray(raw.points)) return { state: 'unavailable', reason: 'provider usage response has no points' }
  const points: PulseProviderUsagePoint[] = []
  let undecodable = 0
  for (const pt of raw.points) {
    const point = decodeProviderUsagePoint(pt)
    if (point) points.push(point)
    else undecodable += 1
  }
  const reportedNoWindows: PulseReportedNoWindows[] = []
  if (Array.isArray(raw.reported_no_windows)) {
    for (const row of raw.reported_no_windows) {
      if (!isRecord(row)) continue
      const scopeId = asStr(row.scope_id)
      const observedAt = asNum(row.observed_at)
      if (scopeId && observedAt !== null) reportedNoWindows.push({ scope_id: scopeId, observed_at: observedAt })
    }
  }
  return {
    state: 'available',
    days: asNum(raw.days) ?? 1,
    points,
    reported_no_windows: reportedNoWindows,
    undecodable_points: undecodable,
  }
}

export function decodeApprovals(raw: unknown): PulseApprovalItem[] {
  const out: PulseApprovalItem[] = []
  for (const item of decodeToolApprovalsWire(raw)) {
    if (!item.hasExplicitApprovalId) continue
    out.push({
      approval_id: item.approvalId,
      keeper: item.keeper,
      tool_call_id: item.toolCallId,
      tool: item.tool,
      question: item.question,
      because: item.because === '' ? null : item.because,
      asked_at: item.askedAt,
      timeout_sec: item.timeoutSec,
    })
  }
  return out
}

function decodeAsks(raw: unknown): PulseAskItem[] {
  const rec = isRecord(raw) ? raw : {}
  const list = Array.isArray(rec.asks) ? rec.asks : []
  const out: PulseAskItem[] = []
  for (const item of list) {
    if (!isRecord(item)) continue
    if (!isOpenKeeperAskRow(item)) continue
    const askId = asStr(item.ask_id) ?? asStr(item.id)
    const keeper = asStr(item.keeper) ?? asStr(item.keeper_name)
    if (!askId || !keeper) continue
    const questions = Array.isArray(item.questions) ? item.questions : []
    const firstPrompt = questions.length > 0 && isRecord(questions[0])
      ? asStr(questions[0].prompt) ?? asStr(questions[0].question)
      : null
    out.push({
      ask_id: askId,
      keeper,
      summary: asStr(item.summary) ?? asStr(item.title) ?? firstPrompt ?? 'Keeper 응답 대기',
      created_at: asNum(item.created_at) ?? asNum(item.asked_at),
      question_count: Math.max(1, questions.length),
    })
  }
  return out
}

function decodeGoalNode(g: unknown): PulseGoalSummary | null {
  if (!isRecord(g)) return null
  const id = asStr(g.id)
  const title = asStr(g.title)
  if (!id || !title) return null
  const taskSummary = isRecord(g.task_summary) ? g.task_summary : null
  const verification = isRecord(g.verification) ? g.verification : null
  const linkedKeepers = Array.isArray(g.linked_keeper_names)
    ? g.linked_keeper_names.filter((x): x is string => typeof x === 'string' && x.trim().length > 0)
    : []
  // The server counts only a goal's own approvals (`direct_pending_approvals`
  // in dashboard_goals_types_builder.ml), so a parent row adds its sub-goals'.
  const children = Array.isArray(g.children) ? g.children : []
  let subtreePending = asNum(g.pending_approval_count) ?? 0
  let subGoalCount = 0
  for (const child of children) {
    const decoded = decodeGoalNode(child)
    if (!decoded) continue
    subGoalCount += 1 + decoded.sub_goal_count
    subtreePending += decoded.pending_approval_count
  }
  return {
    id,
    title,
    phase: asStr(g.phase),
    task_count: asNum(g.task_count) ?? asNum(taskSummary?.total) ?? 0,
    task_done_count: asNum(g.task_done_count) ?? asNum(taskSummary?.done) ?? 0,
    awaiting_verification_count: asNum(taskSummary?.awaiting_verification) ?? 0,
    pending_approval_count: subtreePending,
    sub_goal_count: subGoalCount,
    verification_status: verification ? (asStr(verification.status) ?? asStr(verification.verdict)) : null,
    linked_keeper_names: linkedKeepers,
    updated_at: asStr(g.updated_at),
  }
}

export function decodeGoals(raw: unknown): PulseGoalsSnapshot {
  const unavailable = goalSourceUnavailable(raw)
  if (unavailable) throw new GoalSourceUnavailableError(unavailable)
  if (!isRecord(raw)) throw new Error('Goal 응답 형식이 잘못되었습니다.')
  const queue = decodeKeeperApprovalQueueState(raw.approval_queue_state)
  if (!queue) throw new Error('Goal 응답의 approval_queue_state 를 읽지 못했습니다.')
  if (queue.state === 'unavailable') {
    return { state: 'approval_queue_unavailable', title: queue.title, detail: queue.operator_detail }
  }
  if (!Array.isArray(raw.tree)) throw new Error('Goal 응답에서 목표 목록을 확인할 수 없습니다.')
  const goals: PulseGoalSummary[] = []
  for (const g of raw.tree) {
    const decoded = decodeGoalNode(g)
    if (decoded) goals.push(decoded)
  }
  const summary = isRecord(raw.summary) ? raw.summary : null
  return {
    state: 'ready',
    goals,
    pending_approval_total: summary ? asNum(summary.pending_approvals) : null,
  }
}

function decodeBoardPosts(raw: unknown): PulseBoardPost[] {
  const rec = isRecord(raw) ? raw : {}
  const list = Array.isArray(rec.posts) ? rec.posts : []
  const out: PulseBoardPost[] = []
  for (const p of list) {
    if (!isRecord(p)) continue
    const id = asStr(p.id)
    const author = asStr(p.author) ?? asStr(p.agent_name)
    if (!id || !author) continue
    const mentions = Array.isArray(p.mentions)
      ? p.mentions.filter((x): x is string => typeof x === 'string')
      : []
    const meta = isRecord(p.meta) ? p.meta : null
    const successionParent = asStr(p.succession_parent_id)
      ?? (meta ? asStr(meta.succession_parent_id) : null)
    out.push({
      id,
      title: asStr(p.title) ?? '',
      body: asStr(p.body) ?? asStr(p.content) ?? '',
      author,
      hearth: asStr(p.hearth) ?? asStr(p.sub_board),
      created_at: asStr(p.created_at),
      reply_count: asNum(p.comment_count) ?? asNum(p.reply_count) ?? 0,
      mentions,
      succession_parent_id: successionParent,
    })
  }
  return out
}

function decodeWorldMemory(raw: unknown): PulseWorldMemoryDigest {
  const rec = isRecord(raw) ? raw : {}
  const inv = isRecord(rec.inventory) ? rec.inventory : {}
  const mvcc = isRecord(rec.world_mvcc) ? rec.world_mvcc : null
  const briefing = isRecord(rec.briefing) ? rec.briefing : {}
  return {
    source: asStr(rec.source),
    ledger_state: rec.ledger_state === 'available' ? 'available' : 'missing',
    claims_count: asNum(inv.claims_count) ?? 0,
    facts_count: asNum(inv.facts_count) ?? 0,
    conflicts_count: asNum(inv.conflicts_count) ?? 0,
    briefing_status: asStr(briefing.status) ?? 'absent',
    briefing_text: asStr(briefing.text),
    wiki_count: mvcc ? asNum(mvcc.wiki_count) : null,
    artifact_count: mvcc ? asNum(mvcc.artifact_count) : null,
  }
}

function decodeCandleDigest(raw: unknown): PulseCandleDigest {
  const rec = isRecord(raw) ? raw : {}
  const policy = isRecord(rec.policy) ? rec.policy : {}
  const halfLife = isRecord(policy.half_life) ? policy.half_life : {}
  const supply = isRecord(rec.supply) ? rec.supply : {}
  const cfg = policy.configuration
  const policyConfig: PulseCandleDigest['policy_configuration'] =
    cfg === 'enabled' ? 'enabled' : cfg === 'disabled' ? 'disabled' : 'off'
  const readMilliStr = (v: unknown): string => {
    if (typeof v === 'string' && v.trim().length > 0) return v.trim()
    if (typeof v === 'number' && Number.isFinite(v)) return String(Math.trunc(v))
    return '0'
  }
  return {
    ledger_state: rec.ledger_state === 'present' ? 'present' : 'missing',
    total_events: asNum(rec.total_events) ?? 0,
    policy_configuration: policyConfig,
    disabled_reason: asStr(policy.disabled_reason),
    pricing_mode: asStr(policy.pricing_mode) ?? 'off',
    half_life_hours: asNum(halfLife.half_life_hours),
    issued_milli: readMilliStr(supply.issued_milli),
    burned_milli: readMilliStr(supply.burned_milli),
    circulating_milli: readMilliStr(supply.circulating_milli),
    active_keepers: asNum(supply.active_keepers) ?? 0,
  }
}

// Authoritative server bound: lib/dashboard/dashboard_http_keeper_feeds.ml:91
// enforces `keeper_costs_max_window_minutes = 1440` (>1440 returns HTTP 400).
export const KEEPER_COSTS_MAX_WINDOW_MINUTES = 1440

export const PULSE_CACHE_KEYS = {
  shell: 'pulse:shell',
  keepers: 'pulse:keepers',
  costs: 'pulse:costs:24h',
  usage: (win: TimeWindow) => `pulse:usage:${win}`,
  approvals: 'pulse:approvals',
  asks: 'pulse:asks',
  goals: 'pulse:goals',
  board: 'pulse:board',
  worldMemory: 'pulse:world-memory',
  candle: 'pulse:candle',
} as const

function wrapResult<T>(p: Promise<Result<T, ApiError>>): Promise<Result<T | null, ApiError>> {
  return p.then(r => (r.ok ? ok<T | null>(r.value) : r))
}

export interface PulseLoadBundle {
  readonly shell: Observed<PulseShellSnapshot>
  readonly keepers: Observed<readonly PulseKeeperRow[]>
  readonly costs: Observed<readonly PulseKeeperCostRow[]>
  readonly usage: Observed<PulseProviderUsageSnapshot>
  readonly approvals: Observed<readonly PulseApprovalItem[]>
  readonly asks: Observed<readonly PulseAskItem[]>
  readonly goals: Observed<PulseGoalsSnapshot>
  readonly board: Observed<readonly PulseBoardPost[]>
  readonly worldMemory: Observed<PulseWorldMemoryDigest>
  readonly candle: Observed<PulseCandleDigest>
}

export function readPulseBundle(win: TimeWindow): PulseLoadBundle {
  const isMultiAccount = authSession.value.kind === 'multi_account_signed_in'
  return {
    shell: resourceCache.observe<PulseShellSnapshot>(PULSE_CACHE_KEYS.shell).value,
    keepers: resourceCache.observe<readonly PulseKeeperRow[]>(PULSE_CACHE_KEYS.keepers).value,
    costs: resourceCache.observe<readonly PulseKeeperCostRow[]>(PULSE_CACHE_KEYS.costs).value,
    usage: resourceCache.observe<PulseProviderUsageSnapshot>(PULSE_CACHE_KEYS.usage(win)).value,
    approvals: isMultiAccount
      ? observedAbsent<readonly PulseApprovalItem[]>('multi_account_unbridged')
      : resourceCache.observe<readonly PulseApprovalItem[]>(PULSE_CACHE_KEYS.approvals).value,
    asks: isMultiAccount
      ? observedAbsent<readonly PulseAskItem[]>('multi_account_unbridged')
      : resourceCache.observe<readonly PulseAskItem[]>(PULSE_CACHE_KEYS.asks).value,
    goals: resourceCache.observe<PulseGoalsSnapshot>(PULSE_CACHE_KEYS.goals).value,
    board: resourceCache.observe<readonly PulseBoardPost[]>(PULSE_CACHE_KEYS.board).value,
    worldMemory: resourceCache.observe<PulseWorldMemoryDigest>(PULSE_CACHE_KEYS.worldMemory).value,
    candle: resourceCache.observe<PulseCandleDigest>(PULSE_CACHE_KEYS.candle).value,
  }
}

export async function loadPulseBundle(
  win: TimeWindow,
  reason: FetchReason = 'mount',
): Promise<void> {
  const usageDays = timeWindowProviderDays(win)
  const isMultiAccount = authSession.peek().kind === 'multi_account_signed_in'

  await Promise.all([
    resourceCache.fetch<PulseShellSnapshot>(
      PULSE_CACHE_KEYS.shell,
      (signal) => wrapResult(apiGet('/api/v1/dashboard/shell', { signal, decode: decodeShell })),
      { ttlMs: 15_000, topics: ['keeper', 'keeper_row_changed', 'keeper_roster_changed', 'task', 'goal', 'goal_projection_changed', 'shell'], reason },
    ),
    resourceCache.fetch<readonly PulseKeeperRow[]>(
      PULSE_CACHE_KEYS.keepers,
      (signal) => wrapResult(apiGet('/api/v1/gate/keepers?detailed=true', { signal, decode: decodePulseKeepers })),
      { ttlMs: 12_000, topics: ['keeper', 'keeper_row_changed', 'keeper_roster_changed', 'keeper_turn_complete', 'provider_standing', 'keeper_turn', 'keeper_lifecycle'], reason },
    ),
    resourceCache.fetch<readonly PulseKeeperCostRow[]>(
      PULSE_CACHE_KEYS.costs,
      (signal) => wrapResult(apiGet(`/api/v1/dashboard/keeper-costs?window=${KEEPER_COSTS_MAX_WINDOW_MINUTES}`, { signal, decode: decodeCosts })),
      { ttlMs: 30_000, topics: ['keeper_turn', 'keeper_turn_complete', 'cost'], reason },
    ),
    resourceCache.fetch<PulseProviderUsageSnapshot>(
      PULSE_CACHE_KEYS.usage(win),
      (signal) => wrapResult(apiGet(`/api/v1/dashboard/provider-usage-history?days=${usageDays}`, { signal, decode: decodeProviderUsage })),
      { ttlMs: 60_000, topics: ['provider', 'provider_standing', 'provider_usage', 'quota'], reason },
    ),
    isMultiAccount
      ? Promise.resolve(observedAbsent<readonly PulseApprovalItem[]>('multi_account_unbridged'))
      : resourceCache.fetch<readonly PulseApprovalItem[]>(
          PULSE_CACHE_KEYS.approvals,
          (signal) => wrapResult(apiGet('/api/v1/keepers/tool-approvals', { signal, decode: decodeApprovals })),
          { ttlMs: 10_000, topics: ['tool_approval', 'keeper_tool_approval_waits_changed', 'keeper_turn'], reason },
        ),
    isMultiAccount
      ? Promise.resolve(observedAbsent<readonly PulseAskItem[]>('multi_account_unbridged'))
      : resourceCache.fetch<readonly PulseAskItem[]>(
          PULSE_CACHE_KEYS.asks,
          (signal) => wrapResult(apiGet('/api/v1/keepers/asks', { signal, decode: decodeAsks })),
          { ttlMs: 10_000, topics: ['keeper_ask', 'keeper_asks_changed', 'ask'], reason },
        ),
    resourceCache.fetch<PulseGoalsSnapshot>(
      PULSE_CACHE_KEYS.goals,
      (signal) => wrapResult(apiGet('/api/v1/dashboard/goals', { signal, decode: decodeGoals })),
      { ttlMs: 20_000, topics: ['goal', 'goals', 'goal_projection_changed', 'verification_requests', 'task'], reason },
    ),
    resourceCache.fetch<readonly PulseBoardPost[]>(
      PULSE_CACHE_KEYS.board,
      (signal) => wrapResult(apiGet('/api/v1/dashboard/board?sort_by=recent&limit=24&exclude_system=true', { signal, decode: decodeBoardPosts })),
      { ttlMs: 20_000, topics: ['board', 'board_changed', 'board_post', 'board_comment'], reason },
    ),
    resourceCache.fetch<PulseWorldMemoryDigest>(
      PULSE_CACHE_KEYS.worldMemory,
      (signal) => wrapResult(apiGetV2('/api/v1/memory/world', { signal, decode: decodeWorldMemory })),
      { ttlMs: 30_000, topics: ['memory', 'world_memory'], reason },
    ),
    resourceCache.fetch<PulseCandleDigest>(
      PULSE_CACHE_KEYS.candle,
      (signal) => wrapResult(apiGetV2('/api/v1/candle/ledger?limit=20', { signal, decode: decodeCandleDigest })),
      { ttlMs: 30_000, topics: ['candle', 'goal'], reason },
    ),
  ])
}
