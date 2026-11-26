/**
 * Pure Pulse domain models, compact human formatters, spend classifier,
 * attention aggregator, company fleet sparklines & multi-keeper handoff extractor.
 */

import type uPlot from 'uplot'
import { formatMilliCandleObserved, isKeeperHealthFailing } from '../../api/keeper-diagnostics'
import {
  observedAbsent,
  observedFailed,
  observedLoading,
  observedUnreported,
  observedValue,
  type Observed,
} from '../../core/resource-cache'
import type { TimeWindow } from '../../core/time-window'
import type {
  PulseApprovalItem,
  PulseAskItem,
  PulseAttentionItem,
  PulseBoardPost,
  PulseFleetGroup,
  PulseHandoffItem,
  PulseKeeperCostRow,
  PulseKeeperRow,
  PulseKpiCard,
  PulseProviderUsageSnapshot,
  PulseShellGroup,
  PulseShellSnapshot,
  SpendClassification,
} from './types'

const TURN_SLOT_SECONDS = 1800

export interface CompactNumber {
  readonly short: string
  readonly exact: string
}

/**
 * Formats counts in compact human notation (`63.2M`, `400k`, `1.2k`, `0`)
 * alongside the exact comma-separated string for hover tooltips.
 * Zero always formats as `"0"`, NEVER `"없음"`.
 */
export function formatCompactCount(value: number): CompactNumber {
  if (!Number.isFinite(value)) {
    return { short: '0', exact: '0' }
  }
  const exact = Math.round(value).toLocaleString('en-US')
  const abs = Math.abs(value)
  const sign = value < 0 ? '-' : ''
  if (abs >= 1_000_000_000) {
    const n = abs / 1_000_000_000
    return { short: `${sign}${trimTrailingZero(n.toFixed(n >= 100 ? 0 : 1))}B`, exact }
  }
  if (abs >= 1_000_000) {
    const n = abs / 1_000_000
    return { short: `${sign}${trimTrailingZero(n.toFixed(n >= 100 ? 0 : 1))}M`, exact }
  }
  if (abs >= 1_000) {
    const n = abs / 1_000
    return { short: `${sign}${trimTrailingZero(n.toFixed(n >= 100 ? 0 : 1))}k`, exact }
  }
  return { short: `${sign}${Math.round(abs)}`, exact }
}

function trimTrailingZero(text: string): string {
  return text.endsWith('.0') ? text.slice(0, -2) : text
}

export function formatCompactUsd(usd: number): string {
  if (!Number.isFinite(usd)) return '$0.00'
  const abs = Math.abs(usd)
  const sign = usd < 0 ? '-' : ''
  if (abs >= 1_000) {
    return `${sign}$${trimTrailingZero((abs / 1_000).toFixed(1))}k`
  }
  if (abs >= 100) {
    return `${sign}$${abs.toFixed(1)}`
  }
  return `${sign}$${abs.toFixed(2)}`
}

/**
 * Formats integer or arbitrary-precision decimal-string milli-Candle values
 * (per #36 wire schema where `supply.*_milli` & `decayed_milli` are decimal strings).
 * Returns `Observed<string>` so missing data is `"없음"` and `"0"` is `"0.000"`.
 */
export function formatMilliCandle(raw: string | number | null | undefined): Observed<string> {
  return formatMilliCandleObserved(raw)
}

/**
 * Returns `Observed<number>` percentage (0..100) for a keeper's context ratio.
 * Keeps `0%` strictly distinct from `"없음"`.
 */
export function observeKeeperContextPct(keeper: PulseKeeperRow): Observed<number> {
  if (typeof keeper.context_ratio === 'number' && Number.isFinite(keeper.context_ratio)) {
    const pct = Math.max(0, Math.min(100, Math.round(keeper.context_ratio * 100)))
    return observedValue(pct)
  }
  if (
    keeper.context_provenance === 'estimated'
    && typeof keeper.estimated_context_ratio === 'number'
    && Number.isFinite(keeper.estimated_context_ratio)
  ) {
    const pct = Math.max(0, Math.min(100, Math.round(keeper.estimated_context_ratio * 100)))
    return observedValue(pct)
  }
  if (keeper.context_unavailable_reason) {
    return observedAbsent(keeper.context_unavailable_reason)
  }
  return observedAbsent()
}

export function isKeeperPathResting(keeper: PulseKeeperRow): boolean {
  if (keeper.runtime_path_rest?.status !== 'resting') return false
  if (keeper.paused || !keeper.keepalive_running) return false
  const h = keeper.health.toLowerCase()
  const p = keeper.phase.toLowerCase()
  return h !== 'offline' && p !== 'offline' && p !== 'stopped' && p !== 'paused'
}

export function isKeeperActive(keeper: PulseKeeperRow): boolean {
  if (keeper.paused || isKeeperFailing(keeper) || isKeeperPathResting(keeper)) return false
  const h = keeper.health.toLowerCase()
  const p = keeper.phase.toLowerCase()
  const s = keeper.status.toLowerCase()
  if (
    h === 'failing'
    || h === 'failed'
    || h === 'offline'
    || p === 'stopped'
    || p === 'paused'
    || p === 'offline'
    || p === 'crashed'
    || p === 'failing'
  ) {
    return false
  }
  return keeper.keepalive_running
    || h === 'healthy'
    || h === 'working'
    || h === 'idle'
    || s === 'running'
    || s === 'active'
}

export function isKeeperFailing(keeper: PulseKeeperRow): boolean {
  return isKeeperHealthFailing(keeper)
}

/**
 * Classifies 24h/window spend honestly into:
 * - reported USD (with subscription / exhausted / unreported sub-counts)
 * - `$0 Sub` (subscription-covered lanes where cost_usd is null/0)
 * - `$0 Exhausted` (provider quota exhausted)
 * - `? Unreported` (telemetry absent/unreported)
 * - `absent` (no spend samples in window)
 */
export function classifySpendStatus(
  costs: Observed<readonly PulseKeeperCostRow[]>,
  usage: Observed<PulseProviderUsageSnapshot>,
  shellCostUsd: number | null,
): SpendClassification {
  let exhaustedCount = 0
  let subscriptionCount = 0

  if (usage.kind === 'value' && usage.data.state === 'available') {
    for (const pt of usage.data.points) {
      if (pt.unit === 'fraction' && pt.value !== null && pt.value >= 0.999) {
        exhaustedCount += 1
      } else if (pt.unit === 'percent' && pt.value !== null && pt.value >= 99.9) {
        exhaustedCount += 1
      } else if (pt.unit === 'credit_balance' && pt.remaining !== null && pt.remaining <= 0) {
        exhaustedCount += 1
      } else if (
        pt.unit === 'credit_unlimited'
        || (pt.unit === 'fraction' && pt.value !== null && pt.value < 0.999)
        || (pt.unit === 'percent' && pt.value !== null && pt.value < 99.9)
      ) {
        subscriptionCount += 1
      }
    }
  }

  if (costs.kind === 'value') {
    const rows = costs.data
    let totalUsd = 0
    let reportedSamples = 0
    let unreportedSamples = 0

    for (const row of rows) {
      reportedSamples += row.cost_reported_samples
      unreportedSamples += row.cost_unreported_samples
      if (row.total_cost_usd !== null) {
        totalUsd += row.total_cost_usd
      }
    }

    if (reportedSamples > 0 && totalUsd > 0) {
      return {
        kind: 'reported',
        usd: totalUsd,
        subscriptionCount,
        exhaustedCount,
        unreportedCount: unreportedSamples,
      }
    }
    if (exhaustedCount > 0 && totalUsd === 0) {
      return { kind: 'exhausted_zero', exhaustedCount }
    }
    if ((subscriptionCount > 0 || unreportedSamples > 0) && totalUsd === 0) {
      return subscriptionCount > 0
        ? { kind: 'subscription_zero', subscriptionCount, exhaustedCount }
        : { kind: 'unreported', reason: `${unreportedSamples}건 비용 미보고 (구독/로컬 레인)` }
    }
    if (reportedSamples > 0) {
      return {
        kind: 'reported',
        usd: 0,
        subscriptionCount,
        exhaustedCount,
        unreportedCount: unreportedSamples,
      }
    }
    if (rows.length === 0 && shellCostUsd === null) {
      return { kind: 'absent' }
    }
  }

  if (shellCostUsd !== null && Number.isFinite(shellCostUsd)) {
    if (shellCostUsd === 0 && exhaustedCount > 0) {
      return { kind: 'exhausted_zero', exhaustedCount }
    }
    if (shellCostUsd === 0 && subscriptionCount > 0) {
      return { kind: 'subscription_zero', subscriptionCount, exhaustedCount }
    }
    return {
      kind: 'reported',
      usd: shellCostUsd,
      subscriptionCount,
      exhaustedCount,
      unreportedCount: 0,
    }
  }

  if (usage.kind === 'value' && usage.data.state === 'unavailable') {
    return { kind: 'unreported', reason: usage.data.reason }
  }

  return { kind: 'unreported', reason: '비용 원장 미보고' }
}

/**
 * Builds the exact 4-KPI Hero Strip for `1 Pulse`.
 * Never adds an orphan 7th card or empty `0.000 Candle` box.
 */
export function buildPulseKpis(params: {
  readonly shell: Observed<PulseShellSnapshot>
  readonly keepers: Observed<readonly PulseKeeperRow[]>
  readonly costs: Observed<readonly PulseKeeperCostRow[]>
  readonly usage: Observed<PulseProviderUsageSnapshot>
  readonly window: TimeWindow
}): readonly PulseKpiCard[] {
  const { shell, keepers, costs, usage, window: win } = params

  // 1. Active Keepers
  let activeKpi: PulseKpiCard
  if (keepers.kind === 'value') {
    const total = keepers.data.length
    const active = keepers.data.filter(isKeeperActive).length
    const failing = keepers.data.filter(isKeeperFailing).length
    const resting = keepers.data.filter((k) => !isKeeperFailing(k) && isKeeperPathResting(k)).length
    const configured = shell.kind === 'value' ? shell.data.counts.configured_keepers : null
    const denom = configured !== null && configured > total ? configured : total
    const subParts: string[] = []
    if (failing > 0) subParts.push(`${failing} 주의 필요`)
    if (resting > 0) subParts.push(`${resting} 경로 휴식`)
    if (subParts.length === 0) subParts.push(`${total - active} 대기/정지`)
    activeKpi = {
      id: 'active_keepers',
      label: 'Active Keepers',
      value: observedValue(`${active} / ${denom}`),
      exactTooltip: `실행 중 ${active} · 전체 ${total}${configured !== null ? ` · 설정 ${configured}` : ''}${failing > 0 ? ` · 주의 ${failing}` : ''}${resting > 0 ? ` · 경로 휴식 ${resting}` : ''}`,
      secondary: subParts.join(' · '),
      tone: failing > 0 || resting > 0 ? 'warn' : active > 0 ? 'ok' : 'default',
      route: '/keepers',
    }
  } else if (keepers.kind === 'loading') {
    activeKpi = {
      id: 'active_keepers',
      label: 'Active Keepers',
      value: observedLoading(),
      exactTooltip: null,
      secondary: null,
      tone: 'default',
      route: '/keepers',
    }
  } else {
    activeKpi = {
      id: 'active_keepers',
      label: 'Active Keepers',
      value: keepers.kind === 'failed' ? keepers : observedAbsent(),
      exactTooltip: null,
      secondary: null,
      tone: keepers.kind === 'failed' ? 'bad' : 'default',
      route: '/keepers',
    }
  }

  // 2. Tasks Done/24h & Awaiting Verify
  let tasksKpi: PulseKpiCard
  if (shell.kind === 'value') {
    const done = shell.data.scorecard.tasks_done_24h ?? shell.data.counts.tasks_done_24h
    const awaiting = shell.data.scorecard.tasks_awaiting_verification
    if (done === null && awaiting === null) {
      tasksKpi = {
        id: 'tasks_24h',
        label: 'Tasks Done / Verify',
        value: observedAbsent(),
        exactTooltip: null,
        secondary: null,
        tone: 'default',
        route: '/work/tasks',
      }
    } else {
      const doneFmt = formatCompactCount(done ?? 0)
      const awaitFmt = awaiting !== null ? formatCompactCount(awaiting) : null
      const rejected = shell.data.scorecard.verifications_rejected_24h ?? 0
      const secParts: string[] = []
      secParts.push(awaitFmt !== null ? `검증 대기 ${awaitFmt.short}` : '검증 대기 없음')
      if (rejected > 0) secParts.push(`거절 ${rejected}`)
      tasksKpi = {
        id: 'tasks_24h',
        label: 'Tasks Done/24h & Verify',
        value: observedValue(doneFmt.short),
        exactTooltip: `24h 완료 ${doneFmt.exact}건${awaitFmt ? ` · 검증 대기 ${awaitFmt.exact}건` : ''}${rejected > 0 ? ` · 24h 거절 ${rejected}건` : ''}`,
        secondary: secParts.join(' · '),
        tone: rejected > 0 ? 'bad' : (awaiting ?? 0) > 0 ? 'warn' : (done ?? 0) > 0 ? 'ok' : 'default',
        route: '/work/tasks',
      }
    }
  } else if (shell.kind === 'loading') {
    tasksKpi = {
      id: 'tasks_24h',
      label: 'Tasks Done/24h & Verify',
      value: observedLoading(),
      exactTooltip: null,
      secondary: null,
      tone: 'default',
      route: '/work/tasks',
    }
  } else {
    tasksKpi = {
      id: 'tasks_24h',
      label: 'Tasks Done/24h & Verify',
      value: shell.kind === 'failed' ? shell : observedAbsent(),
      exactTooltip: null,
      secondary: null,
      tone: shell.kind === 'failed' ? 'bad' : 'default',
      route: '/work/tasks',
    }
  }

  // 3. Turns / 24h (honestly scoped to 24h — server scorecard & recent_turns cap at 86400s)
  let turnsTotal: number | null = null
  let totalTokens: number | null = null
  if (shell.kind === 'value' && shell.data.scorecard.turns_24h !== null) {
    turnsTotal = shell.data.scorecard.turns_24h
  } else if (keepers.kind === 'value') {
    let sum = 0
    let anyPulse = false
    for (const k of keepers.data) {
      if (k.recent_turns) {
        anyPulse = true
        for (const slot of k.recent_turns.slots) {
          sum += slot.ok + slot.rested + slot.failed
        }
      }
    }
    if (anyPulse) turnsTotal = sum
  }
  if (costs.kind === 'value') {
    let tokSum = 0
    let anyTok = false
    for (const c of costs.data) {
      if (c.total_tokens !== null) {
        tokSum += c.total_tokens
        anyTok = true
      }
    }
    if (anyTok) totalTokens = tokSum
  }

  const turnsKpi: PulseKpiCard = turnsTotal === null && (shell.kind === 'loading' || keepers.kind === 'loading')
    ? {
        id: 'turns_24h',
        label: 'Turns / 24h',
        value: observedLoading(),
        exactTooltip: null,
        secondary: null,
        tone: 'default',
        route: '/runtime/efficiency',
      }
    : turnsTotal === null && shell.kind === 'failed' && keepers.kind === 'failed'
      ? {
          id: 'turns_24h',
          label: 'Turns / 24h',
          value: observedFailed(shell.error),
          exactTooltip: shell.error.message,
          secondary: '조회 실패',
          tone: 'bad',
          route: '/runtime/efficiency',
        }
    : turnsTotal === null
      ? {
          id: 'turns_24h',
          label: 'Turns / 24h',
          value: observedAbsent(),
          exactTooltip: null,
          secondary: null,
          tone: 'default',
          route: '/runtime/efficiency',
        }
      : (() => {
          const turnsFmt = formatCompactCount(turnsTotal)
          const tokFmt = totalTokens !== null ? formatCompactCount(totalTokens) : null
          return {
            id: 'turns_24h',
            label: 'Turns / 24h',
            value: observedValue(turnsFmt.short),
            exactTooltip: `24h 턴 ${turnsFmt.exact}${tokFmt ? ` · 24h 토큰 ${tokFmt.exact}` : ''}`,
            secondary: tokFmt ? `${tokFmt.short} tokens` : '토큰 미보고',
            tone: 'brass',
            route: '/runtime/efficiency',
          }
        })()

  // 4. Spend / 24h ($0 Sub / $0 Exhausted / ? Unreported aware; keeper-costs caps at 1440m)
  const shellCost = shell.kind === 'value' ? shell.data.scorecard.cost_24h_usd : null
  const cls = classifySpendStatus(costs, usage, shellCost)
  const scopeNote = win === '24h' ? '' : ` (비용 24h · 쿼터 ${win === '7d' ? '7d' : '14d'})`
  let spendKpi: PulseKpiCard
  if ((cls.kind === 'absent' || cls.kind === 'unreported')
      && (costs.kind === 'loading' || shell.kind === 'loading' || usage.kind === 'loading')) {
    spendKpi = {
      id: 'spend_24h',
      label: 'Spend / 24h',
      value: observedLoading(),
      exactTooltip: null,
      secondary: null,
      tone: 'default',
      route: '/runtime/quotas',
    }
  } else if (costs.kind === 'failed' && shell.kind === 'failed' && usage.kind !== 'value') {
    spendKpi = {
      id: 'spend_24h',
      label: 'Spend / 24h',
      value: observedFailed(costs.error),
      exactTooltip: costs.error.message,
      secondary: `조회 실패${scopeNote}`,
      tone: 'bad',
      route: '/runtime/quotas',
    }
  } else {
    switch (cls.kind) {
      case 'reported':
        spendKpi = {
          id: 'spend_24h',
          label: 'Spend / 24h',
          value: observedValue(formatCompactUsd(cls.usd)),
          exactTooltip: `24h 정확한 비용 $${cls.usd.toFixed(4)} · 구독 레인 ${cls.subscriptionCount} · 미보고 ${cls.unreportedCount} · 한도소진 ${cls.exhaustedCount}${scopeNote}`,
          secondary: cls.exhaustedCount > 0
            ? `한도 소진 ${cls.exhaustedCount}${scopeNote}`
            : cls.subscriptionCount > 0
              ? `구독 ${cls.subscriptionCount} 병행${scopeNote}`
              : cls.unreportedCount > 0
                ? `? 미보고 ${cls.unreportedCount} 포함${scopeNote}`
                : `API 과금 측정${scopeNote}`,
          tone: cls.exhaustedCount > 0 ? 'warn' : 'default',
          route: '/runtime/quotas',
        }
        break
      case 'subscription_zero':
        spendKpi = {
          id: 'spend_24h',
          label: 'Spend / 24h',
          value: observedValue('$0 Sub'),
          exactTooltip: `구독 플랜 레인 ${cls.subscriptionCount}개 활성 (24h API 직접 과금 $0.00)${scopeNote}`,
          secondary: `구독 플랜 ${cls.subscriptionCount}개 활성${scopeNote}`,
          tone: 'ok',
          route: '/runtime/quotas',
        }
        break
      case 'exhausted_zero':
        spendKpi = {
          id: 'spend_24h',
          label: 'Spend / 24h',
          value: observedValue('$0 Exhausted'),
          exactTooltip: `쿼터 소진 레인 ${cls.exhaustedCount}개 감지${scopeNote}`,
          secondary: `쿼터 소진 ${cls.exhaustedCount}건${scopeNote}`,
          tone: 'bad',
          route: '/runtime/quotas',
        }
        break
      case 'unreported':
        spendKpi = {
          id: 'spend_24h',
          label: 'Spend / 24h',
          value: observedUnreported(cls.reason),
          exactTooltip: `${cls.reason}${scopeNote}`,
          secondary: `? Unreported${scopeNote}`,
          tone: 'default',
          route: '/runtime/quotas',
        }
        break
      case 'absent':
        spendKpi = {
          id: 'spend_24h',
          label: 'Spend / 24h',
          value: observedAbsent(),
          exactTooltip: `24h 비용 기록 없음${scopeNote}`,
          secondary: `24h 기록 없음${scopeNote}`,
          tone: 'default',
          route: '/runtime/quotas',
        }
        break
    }
  }

  return [activeKpi, tasksKpi, turnsKpi, spendKpi]
}

export function buildAttentionQueue(params: {
  readonly approvals: readonly PulseApprovalItem[]
  readonly asks: readonly PulseAskItem[]
  readonly keepers: readonly PulseKeeperRow[]
  readonly nowSec: number
}): readonly PulseAttentionItem[] {
  const { approvals, asks, keepers, nowSec } = params
  const items: PulseAttentionItem[] = []

  for (const app of approvals) {
    items.push({
      id: `approval:${app.approval_id}`,
      kind: 'approval',
      severity: 'critical',
      keeper: app.keeper,
      title: `도구 승인 요청 · ${app.tool || 'tool'}`,
      detail: app.question || `call ${app.tool_call_id}`,
      ageSec: app.asked_at !== null ? Math.max(0, Math.round(nowSec - app.asked_at)) : null,
      route: '/work/inbox',
      raw: app,
    })
  }

  for (const ask of asks) {
    items.push({
      id: `ask:${ask.ask_id}`,
      kind: 'ask',
      severity: 'warn',
      keeper: ask.keeper,
      title: `Keeper 질문 (${ask.question_count})`,
      detail: ask.summary,
      ageSec: ask.created_at !== null ? Math.max(0, Math.round(nowSec - ask.created_at)) : null,
      route: '/work/inbox',
      raw: ask,
    })
  }

  for (const k of keepers) {
    if (isKeeperFailing(k)) {
      const failSummary = k.directory_issue
        ?? k.runtime_blocker_summary
        ?? (k.runtime_lane_failures && k.runtime_lane_failures.length > 0
          ? k.runtime_lane_failures.map((f) => `${f.runtime_id ?? 'lane'}: ${f.summary}`).join(' → ')
          : null)
        ?? (k.last_failure ? `최근 실패: ${k.last_failure.cause}` : `상태: ${k.health}`)
      const actionableDisposition =
        k.operator_disposition && k.operator_disposition !== 'pass'
          ? k.operator_disposition
          : null
      const detail = actionableDisposition
        ? `${failSummary} · 조치: ${actionableDisposition}`
        : failSummary
      const sinceUnix = k.failing_since ?? k.last_failure?.at_unix ?? null
      const ageSec = sinceUnix != null
        ? Math.max(0, Math.round(nowSec - sinceUnix))
        : null
      items.push({
        id: `keeper:${k.name}`,
        kind: 'keeper_failure',
        severity: k.health.toLowerCase() === 'degraded' ? 'warn' : 'critical',
        keeper: k.name,
        title: `${k.name} · ${k.directory_issue ? '설정 오류' : k.health}`,
        detail,
        ageSec,
        route: `/keepers/${encodeURIComponent(k.name)}/chat`,
        raw: k,
      })
    } else if (isKeeperPathResting(k)) {
      const rest = k.runtime_path_rest!
      const detail = `경로 휴식 (${rest.runtime_id ?? k.runtime_id})${rest.release_at ? ` · 해제 ${rest.release_at}` : ''}${rest.release_basis ? ` · ${rest.release_basis}` : ''}`
      items.push({
        id: `keeper-rest:${k.name}`,
        kind: 'keeper_failure',
        severity: 'warn',
        keeper: k.name,
        title: `${k.name} · 경로 휴식`,
        detail,
        ageSec: null,
        route: `/keepers/${encodeURIComponent(k.name)}/chat`,
        raw: k,
      })
    }
  }

  const rank: Record<PulseAttentionItem['severity'], number> = { critical: 0, warn: 1, info: 2 }
  return items.sort((a, b) => {
    const sevDiff = rank[a.severity] - rank[b.severity]
    if (sevDiff !== 0) return sevDiff
    return (b.ageSec ?? 0) - (a.ageSec ?? 0)
  })
}

export function classifyKeeperCompany(
  keeperName: string,
  shellGroupByKeeper: ReadonlyMap<string, string>,
): string {
  const fromShell = shellGroupByKeeper.get(keeperName)
  if (fromShell && fromShell.trim()) return fromShell.trim()
  const dashIdx = keeperName.indexOf('-')
  if (dashIdx > 0) return keeperName.slice(0, dashIdx)
  return 'General'
}

/**
 * Builds wall-time anchored 24h `uPlot.AlignedData` (48 half-hour slots) for a group of Keepers.
 * Server `recent_turns.slots` is strictly a 24h rolling pulse (`window_seconds = 86400`),
 * and slots prior to `known_since` emit `null` (unobserved gap, NEVER fabricated `0`).
 */
export function buildGroupSparklineData(
  keepers: readonly PulseKeeperRow[],
  _win: TimeWindow,
  nowSec: number,
): {
  readonly aligned: uPlot.AlignedData
  readonly totalTurns: number
  readonly okTurns: number
  readonly restedTurns: number
  readonly failedTurns: number
} {
  const bucketSeconds = TURN_SLOT_SECONDS
  const bucketCount = 48
  const currentBucket = Math.floor(nowSec / bucketSeconds) * bucketSeconds
  const startBucket = currentBucket - (bucketCount - 1) * bucketSeconds

  let earliestKnownSince: number | null = null
  for (const k of keepers) {
    if (!k.recent_turns) continue
    const ks = k.recent_turns.known_since
    if (earliestKnownSince === null || ks < earliestKnownSince) {
      earliestKnownSince = ks
    }
  }

  const xs: number[] = []
  const ys: (number | null)[] = []
  const indexByBucket = new Map<number, number>()

  for (let i = 0; i < bucketCount; i += 1) {
    const ts = startBucket + i * bucketSeconds
    xs.push(ts)
    // Emit `null` (gap) before `known_since` or when no keeper reported a turn pulse
    const observed = earliestKnownSince !== null && ts + bucketSeconds > earliestKnownSince
    ys.push(observed ? 0 : null)
    indexByBucket.set(ts, i)
  }

  let totalTurns = 0
  let okTurns = 0
  let restedTurns = 0
  let failedTurns = 0
  for (const k of keepers) {
    if (!k.recent_turns) continue
    for (const slot of k.recent_turns.slots) {
      const bucketTs = Math.floor(slot.starts_at / bucketSeconds) * bucketSeconds
      const idx = indexByBucket.get(bucketTs)
      if (idx === undefined) continue
      const count = slot.ok + slot.rested + slot.failed
      ys[idx] = (ys[idx] ?? 0) + count
      totalTurns += count
      okTurns += slot.ok
      restedTurns += slot.rested
      failedTurns += slot.failed
    }
  }

  return { aligned: [xs, ys], totalTurns, okTurns, restedTurns, failedTurns }
}

export function buildCompanyFleetGroups(params: {
  readonly keepers: readonly PulseKeeperRow[]
  readonly shellGroups: readonly PulseShellGroup[]
  readonly window: TimeWindow
  readonly nowSec: number
}): readonly PulseFleetGroup[] {
  const { keepers, shellGroups, window: win, nowSec } = params
  const groupByKeeper = new Map<string, string>()
  for (const g of shellGroups) {
    for (const name of g.keepers) {
      groupByKeeper.set(name, g.group)
    }
  }

  const buckets = new Map<string, PulseKeeperRow[]>()
  for (const k of keepers) {
    const company = classifyKeeperCompany(k.name, groupByKeeper)
    const list = buckets.get(company) ?? []
    list.push(k)
    buckets.set(company, list)
  }

  const groups: PulseFleetGroup[] = []
  for (const [company, list] of buckets.entries()) {
    const sorted = [...list].sort((a, b) => a.name.localeCompare(b.name))
    const { aligned, totalTurns, okTurns, restedTurns, failedTurns } = buildGroupSparklineData(sorted, win, nowSec)
    groups.push({
      company,
      keepers: sorted,
      activeCount: sorted.filter(isKeeperActive).length,
      failingCount: sorted.filter(isKeeperFailing).length,
      restingCount: sorted.filter((k) => !isKeeperFailing(k) && isKeeperPathResting(k)).length,
      turnsInWindow: totalTurns,
      okTurnsInWindow: okTurns,
      restedTurnsInWindow: restedTurns,
      failedTurnsInWindow: failedTurns,
      sparklineData: aligned,
      window: '24h',
    })
  }

  return groups.sort((a, b) => {
    if (a.company === 'General' && b.company !== 'General') return 1
    if (b.company === 'General' && a.company !== 'General') return -1
    if (b.activeCount !== a.activeCount) return b.activeCount - a.activeCount
    return a.company.localeCompare(b.company)
  })
}

/**
 * Extracts lightweight multi-keeper collaboration / handoff / succession entries
 * from recent Board posts — zero Cytoscape overhead.
 */
export function buildTeamHandoffPulse(
  posts: readonly PulseBoardPost[],
  knownKeepers: readonly PulseKeeperRow[],
  limit = 8,
): readonly PulseHandoffItem[] {
  const knownSet = new Set(knownKeepers.map(k => k.name))
  const results: PulseHandoffItem[] = []

  for (const post of posts) {
    if (results.length >= limit) break
    const extractedMentions = new Set<string>()
    for (const m of post.mentions) {
      if (m && m !== post.author) extractedMentions.add(m)
    }
    const text = `${post.title} ${post.body}`
    for (const match of text.matchAll(/@([a-zA-Z0-9_-]{2,48})/g)) {
      const candidate = match[1]
      if (candidate && candidate !== post.author && (knownSet.size === 0 || knownSet.has(candidate))) {
        extractedMentions.add(candidate)
      }
    }
    const targets = [...extractedMentions]
    const isSuccession = post.succession_parent_id !== null
    const kind: PulseHandoffItem['kind'] = isSuccession
      ? 'succession'
      : targets.length > 0
        ? 'handoff'
        : 'collab'

    if (kind === 'collab' && post.reply_count === 0 && !knownSet.has(post.author)) {
      continue
    }

    results.push({
      id: post.id,
      fromKeeper: post.author,
      toKeepers: targets.slice(0, 3),
      kind,
      title: post.title || post.body.slice(0, 72),
      hearth: post.hearth,
      replyCount: post.reply_count,
      createdAt: post.created_at,
      route: `/knowledge/board/${encodeURIComponent(post.id)}`,
    })
  }

  return results
}

export function formatRelativeAge(ageSec: number | null): string {
  if (ageSec === null || !Number.isFinite(ageSec)) return '없음'
  if (ageSec < 60) return `${Math.max(0, Math.round(ageSec))}s`
  if (ageSec < 3600) return `${Math.floor(ageSec / 60)}m`
  if (ageSec < 86400) return `${Math.floor(ageSec / 3600)}h`
  return `${Math.floor(ageSec / 86400)}d`
}
