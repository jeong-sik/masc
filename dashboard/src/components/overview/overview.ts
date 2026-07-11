// MASC Dashboard — Overview (slim home)
//
// "What's the party doing today?" in one glance, no scroll. Rendered sections,
// top-to-bottom:
//   - Header       — namespace, keeper count, operator, live clock
//   - KPI strip    — running / attention / open approvals / top goal /
//                    active connectors / pending schedule approvals / fusion runs
//   - Attention    — keepers flagged for operator attention with reason + action
//   - Telemetry    — deterministic 28-bar trace histogram
//   - Domain cards — work/approvals/schedule/fusion/board/connectors/fleet summary
//
// Every KPI/card reads its owning domain's projection directly (governance
// approval queue, gate connectors, scheduled-automation, fusion runs, board
// total) rather than a parallel derivation — see computeOverviewDigest and the
// per-panel resources below.

import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { AgentAvatar } from './agent-avatar'
import { keepers, boardTotal, goals, fusionRuns } from '../../store'
import type { Keeper, Goal, KeeperRuntimeBlockerClass } from '../../types/core'
import type { FusionRunRecord } from '../../api/dashboard'
import type { KeeperApprovalQueueItem } from '../../types/governance'
import { useNowSecondsTicker } from '../../lib/now-signal'
import { keeperDisplayStatus, keeperRuntimeBlockerLabel } from '../../lib/keeper-runtime-display'
import { attentionReasonLabel, nextHumanActionLabel } from '../../lib/keeper-attention-labels'
import { keeperRowLooksRunning } from '../../runtime-counts'
import { createAsyncResource, createManagedAsyncResource, type AsyncResource, type AsyncState } from '../../lib/async-state'
import { navigate } from '../../router'
import type { TabId } from '../../types/sse'
import {
  fetchTelemetry,
  fetchTelemetrySummary,
  type TelemetryEntry,
  type TelemetrySourceSummary,
} from '../../api/dashboard'
import {
  OVERVIEW_TELEMETRY_EVENTS_PER_BUCKET,
} from '../../config/constants'
import { fetchGateConnectors, type GateConnectorsData } from '../../api/gate'
import { governanceData } from '../governance-signals'
import { keeperApprovalRiskVisualBand } from '../../lib/governance-risk-level'
import { toolsData, toolsError } from '../tools/tool-state'
import { scheduledPendingApprovalCount } from '../tools/scheduled-automation-panel'
import type { DashboardScheduledAutomation } from '../../api'

// ─── Attention / Keeper v2 helpers ───────────────────────────────────────────

export interface KeeperAttentionReason {
  sev: 'bad' | 'warn'
  text: string
  act: string
}

const DEFAULT_ATTENTION_REASON: KeeperAttentionReason = { sev: 'warn', text: '주의 사유 미보고', act: '상태 상세' }

const OPERATOR_ATTENTION_BLOCKERS = new Set<KeeperRuntimeBlockerClass>([
  'awaiting_operator',
])

const CRITICAL_ATTENTION_BLOCKERS = new Set<KeeperRuntimeBlockerClass>([
  'exception',
  'turn_failures',
  'heartbeat_failures',
])

function hasOperatorAttentionBlocker(blockerClass: Keeper['runtime_blocker_class'] | null | undefined): boolean {
  return blockerClass != null && OPERATOR_ATTENTION_BLOCKERS.has(blockerClass)
}

function hasCriticalAttentionBlocker(blockerClass: Keeper['runtime_blocker_class'] | null | undefined): boolean {
  return blockerClass != null && CRITICAL_ATTENTION_BLOCKERS.has(blockerClass)
}

/** Map a keeper's runtime/trust state to a human attention reason.
 *  Mirrors the hard-coded ATTN_REASON table from keeper-v2/overview.jsx
 *  but derives the text from live dashboard fields. */
export function deriveKeeperAttentionReason(keeper: Keeper): KeeperAttentionReason {
  const blockerClass = keeper.runtime_blocker_class ?? null
  const blockerLabel = keeperRuntimeBlockerLabel(blockerClass) ?? blockerClass?.replace(/_/g, ' ')
  // Humanize the backend `attention_reason` / `next_human_action` wire codes
  // through the shared SSOT instead of rendering raw tokens like
  // `inspect_blocker_before_resume`. Unknown codes (e.g. composite reasons
  // such as `completion_contract_result:*`) fall back to the raw string and
  // warn in dev — matching the keeper detail alert strip.
  const attentionRaw = keeper.attention_reason?.trim() || keeper.trust?.attention_reason?.trim() || null
  const nextActionRaw = keeper.next_human_action?.trim() || keeper.trust?.next_human_action?.trim() || null
  const attention = attentionReasonLabel(attentionRaw, false) ?? undefined
  const nextAction = nextHumanActionLabel(nextActionRaw) ?? undefined

  if (keeper.runtime_blocker_continue_gate) {
    return {
      sev: 'warn',
      text: attention ?? blockerLabel ?? '계속 진행 승인 대기',
      act: nextAction ?? '승인 검토',
    }
  }

  if (hasOperatorAttentionBlocker(blockerClass)) {
    return { sev: 'warn', text: attention ?? '운영자 조치 대기', act: nextAction ?? '승인 검토' }
  }

  const isCritical = hasCriticalAttentionBlocker(blockerClass)
    || keeper.lifecycle_phase === 'Dead'
    || keeper.lifecycle_phase === 'Crashed'

  if (isCritical) {
    return {
      sev: 'bad',
      text: attention ?? blockerLabel ?? '심각한 실행 장애',
      act: nextAction ?? '재시작',
    }
  }

  if (attention) {
    return { sev: 'warn', text: attention, act: nextAction ?? '대화 열기' }
  }

  return DEFAULT_ATTENTION_REASON
}

/** Keepers flagged for operator attention. */
export function pickAttentionKeepers(keeperList: readonly Keeper[]): Keeper[] {
  return keeperList.filter(k =>
    k.needs_attention === true
    || k.trust?.needs_attention === true
    || k.runtime_blocker_continue_gate === true
    || hasOperatorAttentionBlocker(k.runtime_blocker_class)
    || !!k.attention_reason?.trim()
    || !!k.trust?.attention_reason?.trim(),
  )
}

// ─── KPI stats ───────────────────────────────────────────────────────────────

export interface OverviewStats {
  run: number
  att: number
  hot: number
  total: number
}

export function computeOverviewStats(keeperList: readonly Keeper[]): OverviewStats {
  const total = keeperList.length
  const run = keeperList.filter(keeperRowLooksRunning).length
  const att = pickAttentionKeepers(keeperList).length
  const hot = keeperList.filter(k => (k.context_ratio ?? 0) >= 0.85).length
  return { run, att, hot, total }
}

// ─── Cross-surface digest (overview.jsx:71-92) ───────────────────────────────
//
// Every field reads its owning domain's live projection — the same source its
// dedicated surface renders from — rather than a parallel derivation:
//   - openApprovals/approvalsCritical: governanceData.approval_queue (the HITL
//     queue the Approvals surface itself renders). Earlier this counted
//     keeper runtime_blocker flags instead, an SSOT-violating projection that
//     disagreed with the real queue.
//   - topGoals/topGoalLabel: the `goals` store signal, filtered to active
//     goals so dropped/done goals cannot occupy the "최우선 목표" slot.
//   - fusion*: the `fusionRuns` store signal.

export interface OverviewDigest {
  /** Pending HITL approvals — governanceData.approval_queue.length. */
  openApprovals: number
  /** True when any pending approval sits in the critical/bad risk band. */
  approvalsCritical: boolean
  /** Top ACTIVE goals by priority (highest first), up to 3. */
  topGoals: Goal[]
  /** Title of the top-priority active goal, or null when none is active. */
  topGoalLabel: string | null
  /** Priority of the top-priority active goal (for the KPI's `sub` line). */
  topGoalPriority: number | null
  /** Fusion runs currently executing. */
  fusionRunning: number
  /** Completed fusion runs (status === 'completed'). */
  fusionDone: number
  /** Total fusion runs. */
  fusionTotal: number
  /** Latest fusion run record (newest startedAt), or null. */
  fusionLatest: FusionRunRecord | null
}

function goalPriorityClass(priority: number): 'high' | 'normal' | 'low' {
  // overview.jsx:166 — priority >= 7 high, >= 4 normal, else low
  if (priority >= 7) return 'high'
  if (priority >= 4) return 'normal'
  return 'low'
}

export function computeOverviewDigest(
  goalList: readonly Goal[],
  fusionList: readonly FusionRunRecord[],
  approvalQueue: readonly KeeperApprovalQueueItem[],
): OverviewDigest {
  const approvalsCritical = approvalQueue.some(
    item => keeperApprovalRiskVisualBand(item.risk_level) === 'bad',
  )

  // Active only — dropped/done goals must not occupy the "최우선 목표" slot or
  // the 작업·목표 domain card's top-3. Highest priority first; ties keep input
  // order (stable sort).
  const activeGoals = goalList.filter(g => g.status === 'active')
  const topGoals = [...activeGoals].sort((a, b) => b.priority - a.priority).slice(0, 3)
  const lead = topGoals[0] ?? null
  const topGoalLabel = lead ? lead.title : null
  const topGoalPriority = lead ? lead.priority : null

  const fusionRunning = fusionList.filter(r => r.status === 'running').length
  const fusionDone = fusionList.filter(r => r.status === 'completed').length
  const fusionLatest = [...fusionList].sort((a, b) => b.startedAt - a.startedAt)[0] ?? null

  return {
    openApprovals: approvalQueue.length,
    approvalsCritical,
    topGoals,
    topGoalLabel,
    topGoalPriority,
    fusionRunning,
    fusionDone,
    fusionTotal: fusionList.length,
    fusionLatest,
  }
}

// ─── Telemetry bars ──────────────────────────────────────────────────────────

export const OVERVIEW_TELEMETRY_BAR_COUNT = 28
export const OVERVIEW_TELEMETRY_BUCKET_MINUTES = 5
export const OVERVIEW_TELEMETRY_WINDOW_MINUTES =
  OVERVIEW_TELEMETRY_BAR_COUNT * OVERVIEW_TELEMETRY_BUCKET_MINUTES
export { OVERVIEW_TELEMETRY_EVENTS_PER_BUCKET }
export const OVERVIEW_TELEMETRY_EVENT_SAMPLE_LIMIT =
  OVERVIEW_TELEMETRY_BAR_COUNT * OVERVIEW_TELEMETRY_EVENTS_PER_BUCKET
const UNIX_MS_TIMESTAMP_THRESHOLD = 10_000_000_000

export interface OverviewTelemetrySnapshot {
  bars: number[]
  peakPerBucket: number
  averagePerBucket: number
  eventCount: number
  latestAgeSeconds: number | null
  sourceHealth: string
  activeCoverageGaps: number
  healthySourceCount: number
  sourceCount: number
  truncated: boolean
}

function telemetryEntryMs(entry: TelemetryEntry): number | null {
  const raw = entry.ts_unix ?? entry.ts ?? entry.timestamp
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    // Unix seconds are ~1.7e9 today; unix milliseconds are ~1.7e12.
    return raw > UNIX_MS_TIMESTAMP_THRESHOLD ? raw : raw * 1000
  }
  if (entry.ts_iso) {
    const parsed = Date.parse(entry.ts_iso)
    if (Number.isFinite(parsed)) return parsed
  }
  return null
}

function roundOne(value: number): number {
  return Math.round(value * 10) / 10
}

export function buildOverviewTelemetrySnapshot({
  entries,
  sources,
  nowMs = Date.now(),
  totalMatchingEntries,
  truncated = false,
}: {
  entries: readonly TelemetryEntry[]
  sources: readonly TelemetrySourceSummary[]
  nowMs?: number
  totalMatchingEntries?: number
  truncated?: boolean
}): OverviewTelemetrySnapshot {
  const bucketMs = OVERVIEW_TELEMETRY_BUCKET_MINUTES * 60 * 1000
  const windowMs = OVERVIEW_TELEMETRY_WINDOW_MINUTES * 60 * 1000
  const startMs = nowMs - windowMs
  const buckets = Array.from({ length: OVERVIEW_TELEMETRY_BAR_COUNT }, () => 0)

  for (const entry of entries) {
    const ts = telemetryEntryMs(entry)
    if (ts === null || ts < startMs || ts > nowMs) continue
    const idx = Math.min(
      OVERVIEW_TELEMETRY_BAR_COUNT - 1,
      Math.max(0, Math.floor((ts - startMs) / bucketMs)),
    )
    buckets[idx] = (buckets[idx] ?? 0) + 1
  }

  const peakPerBucket = Math.max(0, ...buckets)
  const averagePerBucket = roundOne(buckets.reduce((sum, count) => sum + count, 0) / buckets.length)
  const oasEventSummary = sources.find(source => source.source === 'oas_event')
  const healthySourceCount = sources.filter(source => source.health === 'ok').length
  const activeCoverageGaps = sources.reduce(
    (sum, source) => sum + (source.active_coverage_gap_count ?? 0),
    0,
  )

  return {
    bars: peakPerBucket > 0 ? buckets.map(count => count / peakPerBucket) : buckets,
    peakPerBucket,
    averagePerBucket,
    eventCount: totalMatchingEntries ?? entries.length,
    latestAgeSeconds: oasEventSummary?.latest_age_s ?? null,
    sourceHealth: oasEventSummary?.health ?? 'unknown',
    activeCoverageGaps,
    healthySourceCount,
    sourceCount: sources.length,
    truncated,
  }
}

// ─── Surface Readiness Summary ───────────────────────────────────────────────

const overviewTelemetryResource: AsyncResource<OverviewTelemetrySnapshot> = createAsyncResource()

function loadOverviewTelemetry(nowMs = Date.now()): Promise<void> {
  return overviewTelemetryResource.load(async () => {
    const sinceMs = nowMs - OVERVIEW_TELEMETRY_WINDOW_MINUTES * 60 * 1000
    const [telemetry, summary] = await Promise.all([
      fetchTelemetry({
        source: 'oas_event',
        since_ms: sinceMs,
        n: OVERVIEW_TELEMETRY_EVENT_SAMPLE_LIMIT,
      }),
      fetchTelemetrySummary(),
    ])
    return buildOverviewTelemetrySnapshot({
      entries: telemetry.entries,
      sources: summary.sources,
      nowMs,
      totalMatchingEntries: telemetry.total_matching_entries,
      truncated: telemetry.truncated ?? false,
    })
  })
}

// ─── Gate connectors (활성 커넥터 KPI + 커넥터 domain card) ───────────────────────
//
// Managed (stale-while-revalidate): the previously loaded connector list stays
// visible while a periodic refetch is in flight, matching the governance/tools
// resources this surface also reads from.

const overviewConnectorsResource = createManagedAsyncResource<GateConnectorsData>()

function loadOverviewConnectors(): Promise<GateConnectorsData | undefined> {
  return overviewConnectorsResource.load(signal => fetchGateConnectors(signal))
}

// ─── Keeper-v2 overview surfaces ─────────────────────────────────────────────

function nowHMKst(): string {
  const d = new Date()
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`
}

function OverviewHeader() {
  useNowSecondsTicker()
  const clock = nowHMKst()
  return html`
    <header class="ov-head v2-overview-head" data-testid="overview-head">
      <div>
        <!-- eyebrow + display header + purpose: overview.jsx:99-101 (copy verbatim) -->
        <span class="ov-eyebrow">운영 홈</span>
        <h1>지금, 전체</h1>
        <p class="ov-sub">fleet 전체 — 목표 · 승인 · 심의 · 연결 한눈에</p>
      </div>
      <div class="ov-clock v2-overview-clock mono" data-testid="overview-clock">
        ${clock} <span>KST</span>
      </div>
    </header>
  `
}

function OverviewKpi({
  label,
  value,
  sub,
  tone,
  testId,
  onClick,
}: {
  label: string
  value: string
  sub?: string
  tone?: 'ok' | 'bad' | 'warn' | 'volt'
  testId: string
  onClick?: () => void
}) {
  // overview.jsx:16-25 — clickable KPI cell gets .link + button role + keyboard handler
  const onKeyDown = onClick
    ? (e: KeyboardEvent) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          onClick()
        }
      }
    : undefined
  return html`
    <div
      class=${`ov-kpi ${onClick ? 'link' : ''}`}
      data-testid=${testId}
      onClick=${onClick}
      role=${onClick ? 'button' : undefined}
      tabIndex=${onClick ? 0 : undefined}
      onKeyDown=${onKeyDown}
    >
      <div class="ov-kpi-k">${label}</div>
      <div class=${`ov-kpi-v ${tone ?? ''}`}>${value}${sub !== undefined ? html`<small>${sub}</small>` : null}</div>
    </div>
  `
}

// Cross-surface KPI row — overview.jsx:106-114. Seven cells, each a deep link into
// its surface. Labels and `sub` separators are copied verbatim from the prototype.
function OverviewKpiStrip({
  stats,
  digest,
  connectorsData,
  scheduledPending,
}: {
  stats: OverviewStats
  digest: OverviewDigest
  connectorsData: GateConnectorsData | null
  scheduledPending: number
}) {
  return html`
    <section class="ov-kpis v2-overview-kpis" aria-label="Cross-surface KPIs" data-testid="overview-kpis">
      <${OverviewKpi} label="실행 중 keeper" value=${String(stats.run)} sub=${` / ${stats.total}`} tone="ok" testId="kpi-run" onClick=${() => navigate('monitoring')} />
      <${OverviewKpi} label="주의 필요" value=${String(stats.att)} tone=${stats.att > 0 ? 'bad' : undefined} testId="kpi-att" onClick=${() => navigate('monitoring')} />
      <${OverviewKpi} label="열린 승인" value=${String(digest.openApprovals)} tone=${digest.approvalsCritical ? 'bad' : digest.openApprovals > 0 ? 'warn' : undefined} testId="kpi-approvals" onClick=${() => navigate('approvals')} />
      <${OverviewKpi} label="최우선 목표" value=${digest.topGoalLabel ?? '—'} sub=${digest.topGoalPriority !== null ? `P${digest.topGoalPriority}` : undefined} tone="volt" testId="kpi-top-goal" onClick=${() => navigate('workspace', { section: 'work' })} />
      <${OverviewKpi} label="활성 커넥터" value=${connectorsData ? String(connectorsData.active_count) : '—'} sub=${connectorsData ? ` / ${connectorsData.connectors.length}` : undefined} testId="kpi-connectors" onClick=${() => navigate('connectors')} />
      <${OverviewKpi} label="예약 승인" value=${String(scheduledPending)} tone=${scheduledPending > 0 ? 'warn' : undefined} testId="kpi-schedule" onClick=${() => navigate('schedule')} />
      <${OverviewKpi} label="진행 심의" value=${String(digest.fusionRunning)} sub=${digest.fusionDone > 0 ? ` · 완료 ${digest.fusionDone}` : undefined} tone=${digest.fusionRunning > 0 ? 'volt' : undefined} testId="kpi-fusion" onClick=${() => navigate('fusion')} />
    </section>
  `
}

function attentionToneClass(sev: KeeperAttentionReason['sev']): string {
  return sev === 'bad' ? 'bg-destructive' : 'bg-warning'
}

function OverviewAttentionPanel({ keeperList }: { keeperList: readonly Keeper[] }) {
  const attn = useMemo(
    () => pickAttentionKeepers(keeperList).slice().sort((a, b) => {
      const aBad = deriveKeeperAttentionReason(a).sev === 'bad'
      const bBad = deriveKeeperAttentionReason(b).sev === 'bad'
      if (aBad && !bBad) return -1
      if (!aBad && bBad) return 1
      return (b.context_ratio ?? 0) - (a.context_ratio ?? 0)
    }),
    [keeperList],
  )

  if (attn.length === 0) {
    return html`
      <section class="ov-card ov-attn v2-overview-attention" data-testid="overview-attention">
        <div class="ov-card-h">
          <h3>주의 필요 · 지금 손이 필요한 것</h3>
          <span class="ov-count">0</span>
        </div>
        <div class="ov-empty">모든 keeper 정상</div>
      </section>
    `
  }

  return html`
    <section class="ov-card ov-attn v2-overview-attention" data-testid="overview-attention">
      <div class="ov-card-h">
        <h3>주의 필요 · 지금 손이 필요한 것</h3>
        <span class="ov-count">${attn.length}</span>
      </div>
      <div class="ov-attn-list v2-overview-attention-list">
        ${attn.map(k => {
          const reason = deriveKeeperAttentionReason(k)
          const displayName = k.koreanName && k.koreanName !== '' ? k.koreanName : k.name
          return html`
            <div
              key=${k.name}
              class="ov-attn-row v2-overview-attention-row"
              onClick=${() => navigate('monitoring', { section: 'agents', keeper: k.name })}
              data-testid=${`attention-row-${k.name}`}
            >
              <${AgentAvatar} name=${k.name} size="sm" status=${keeperDisplayStatus(k)} />
              <div class="ov-attn-meta">
                <div class="ov-attn-name">
                  ${displayName}
                  ${displayName === k.name
                    ? null
                    : html`<span class="ov-attn-ns mono">${k.name}</span>`}
                </div>
                <div class=${`ov-attn-reason sev-${reason.sev}`}>
                  <span class="inline-block size-1.5 rounded-full ${attentionToneClass(reason.sev)}"></span>
                  <span>${reason.text}</span>
                </div>
              </div>
              <button
                type="button"
                class="ov-attn-act"
                onClick=${(e: MouseEvent) => {
                  e.stopPropagation()
                  navigate('monitoring', { section: 'agents', keeper: k.name })
                }}
              >
                ${reason.act} →
              </button>
            </div>
          `
        })}
      </div>
    </section>
  `
}

function formatTelemetryAge(seconds: number | null): string {
  if (seconds === null || !Number.isFinite(seconds)) return 'n/a'
  if (seconds < 60) return `${Math.round(seconds)}s`
  if (seconds < 3600) return `${Math.round(seconds / 60)}m`
  return `${roundOne(seconds / 3600)}h`
}

function telemetryHealthToneClass(snapshot: OverviewTelemetrySnapshot): string {
  if (snapshot.activeCoverageGaps > 0) return 'text-warning'
  if (snapshot.sourceHealth === 'ok') return 'text-success'
  return 'text-text-tertiary'
}

function OverviewTelemetry({
  telemetry,
}: {
  telemetry: AsyncState<OverviewTelemetrySnapshot>
}) {
  const snapshot = telemetry.status === 'loaded' ? telemetry.data : null
  const sampledLabel = snapshot?.truncated ? ' 샘플' : ''
  return html`
    <section class="ov-card ov-telemetry v2-overview-telemetry" data-testid="overview-telemetry">
      <div class="ov-card-h">
        <h3>텔레메트리</h3>
        <button type="button" class="ov-link" onClick=${() => navigate('logs')}>로그 보기 →</button>
      </div>
      ${snapshot
        ? html`
          <div class="ov-bars v2-overview-bars" role="img" aria-label="Live OAS telemetry histogram">
            ${snapshot.bars.map((b, i) => html`
              <span
                key=${i}
                class=${`ov-bar v2-overview-bar ${b >= 0.95 ? 'hot is-hot' : ''}`}
                style=${{ height: `${10 + b * 90}%` }}
              ></span>
            `)}
          </div>
          <div class="ov-tel-foot">
            <div class="ov-tel-stat"><span class="k">피크${sampledLabel}</span><span class="v mono">${snapshot.peakPerBucket}/5m</span></div>
            <div class="ov-tel-stat"><span class="k">평균${sampledLabel}</span><span class="v mono">${snapshot.averagePerBucket}/5m</span></div>
            <div class="ov-tel-stat"><span class="k">이벤트</span><span class="v mono">${snapshot.eventCount.toLocaleString()}${snapshot.truncated ? '+' : ''}</span></div>
            <div class="ov-tel-stat"><span class="k">최신</span><span class=${`v mono ${telemetryHealthToneClass(snapshot)}`}>${formatTelemetryAge(snapshot.latestAgeSeconds)}</span></div>
            <div class="ov-tel-stat"><span class="k">소스</span><span class="v mono">${snapshot.healthySourceCount}/${snapshot.sourceCount}</span></div>
            <div class="ov-tel-stat"><span class="k">갭</span><span class=${`v mono ${snapshot.activeCoverageGaps > 0 ? 'text-warning' : 'text-success'}`}>${snapshot.activeCoverageGaps}</span></div>
          </div>
        `
        : html`
          <div class="ov-empty">
            ${telemetry.status === 'error'
              ? `텔레메트리 로드 실패: ${telemetry.message}`
              : '실제 telemetry 로드 중'}
          </div>
        `}
    </section>
  `
}

// ─── Domain status section (overview.jsx:159-261) ────────────────────────────
//
// "도메인 현황" header over a 7-card grid: one summary card per surface
// (work · approvals · schedule · fusion · board · connectors · fleet), each a
// deep link. Card chrome mirrors the prototype DomainCard (overview.jsx:42-53).

type DomainTone = 'ok' | 'bad' | 'warn' | 'volt'

type DomainNav = { tab: TabId; params?: Record<string, string> }

function DomainCard({
  title,
  count,
  tone,
  linkLabel,
  nav,
  testId,
  children,
}: {
  title: string
  count?: string | null
  tone?: DomainTone
  linkLabel: string
  nav: DomainNav
  testId: string
  children: unknown
}) {
  return html`
    <section class="ov-dcard v2-overview-dcard" data-testid=${testId}>
      <div class="ov-dcard-h">
        <h3>${title}</h3>
        ${count != null ? html`<span class=${`ov-dcount ${tone ?? ''}`}>${count}</span>` : null}
        <button type="button" class="ov-dlink" onClick=${() => navigate(nav.tab, nav.params)}>${linkLabel} →</button>
      </div>
      <div class="ov-dcard-body">${children}</div>
    </section>
  `
}

function OverviewDomainSection({
  stats,
  digest,
  connectorsData,
  connectorsError,
  automation,
  automationError,
  scheduledPending,
}: {
  stats: OverviewStats
  digest: OverviewDigest
  connectorsData: GateConnectorsData | null
  connectorsError: string | null
  automation: DashboardScheduledAutomation | null
  automationError: string | null
  scheduledPending: number
}) {
  return html`
    <h2 class="ov-section-h v2-overview-section-h" data-testid="overview-domains-header">도메인 현황</h2>
    <div class="ov-domains v2-overview-domains" data-testid="overview-domains">
      <!-- WORK · overview.jsx:162-179 -->
      <${DomainCard} title="작업 · 목표" linkLabel="작업" nav=${{ tab: 'workspace', params: { section: 'work' } }} testId="domain-work">
        ${digest.topGoals.length > 0
          ? digest.topGoals.map(g => {
              const pri = goalPriorityClass(g.priority)
              return html`
                <div key=${g.id} class="ov-goal">
                  <div class="ov-goal-top">
                    <span class=${`ov-goal-pri ${pri}`}></span>
                    <span class="ov-goal-title">${g.title}</span>
                    <span class="ov-goal-due mono">${g.due_date ?? ''}</span>
                  </div>
                  <div class="ov-goal-sub mono">P${g.priority} · ${g.phase}</div>
                </div>
              `
            })
          : html`<div class="ov-mini-empty ov-empty">활성 목표 없음</div>`}
      <//>

      <!-- APPROVALS · overview.jsx:182-198 -->
      <${DomainCard}
        title="승인 큐"
        count=${String(digest.openApprovals)}
        tone=${digest.approvalsCritical ? 'bad' : 'warn'}
        linkLabel="승인"
        nav=${{ tab: 'approvals' }}
        testId="domain-approvals"
      >
        <div class="ov-mini-list">
          ${digest.openApprovals > 0
            ? html`
                <div class="ov-mini-row">
                  <span class="inline-block size-1.5 rounded-full ${digest.approvalsCritical ? 'bg-destructive' : 'bg-warning'}"></span>
                  <span class="ov-mini-txt">운영자 조치 대기 ${digest.openApprovals}건</span>
                </div>
              `
            : html`<div class="ov-mini-empty ov-empty">대기 중 승인 없음</div>`}
        </div>
      <//>

      <!-- SCHEDULE · overview.jsx:201-215 -->
      <${DomainCard} title="예약 · 자동화" linkLabel="예약" nav=${{ tab: 'schedule' }} testId="domain-schedule">
        <div class="ov-mini-list">
          ${automation
            ? html`
                <div class="ov-mini-row">
                  <span class="inline-block size-1.5 rounded-full ${scheduledPending > 0 ? 'bg-warning' : 'bg-ok'}"></span>
                  <span class="ov-mini-txt">${scheduledPending > 0 ? `승인 대기 ${scheduledPending}건` : '승인 대기 없음'}</span>
                </div>
                <div class="ov-stat-row"><span class="k">전체 예약</span><span class="v mono">${(automation.requests ?? []).length}</span></div>
              `
            : html`<div class="ov-mini-empty ov-empty">${automationError ? `예약 로드 실패: ${automationError}` : '예약 데이터 로드 중'}</div>`}
        </div>
      <//>

      <!-- FUSION · overview.jsx:218-230 -->
      <${DomainCard}
        title="Fusion 심의"
        count=${String(digest.fusionTotal)}
        tone="volt"
        linkLabel="Fusion"
        nav=${{ tab: 'fusion' }}
        testId="domain-fusion"
      >
        ${digest.fusionLatest
          ? html`
              <div class="ov-fus">
                <div class="ov-fus-h">
                  <span class="ov-fus-run mono">${digest.fusionLatest.runId}</span>
                </div>
                <div class="ov-fus-by mono">${digest.fusionLatest.keeper} · ${digest.fusionLatest.preset}</div>
              </div>
            `
          : null}
        <div class="ov-fus-foot">
          ${digest.fusionRunning > 0
            ? html`<span class="ov-fus-live"><span class="inline-block size-1.5 rounded-full bg-warning"></span>${digest.fusionRunning}건 심의 중</span>`
            : html`<span class="ov-fus-idle">진행 중 심의 없음</span>`}
        </div>
      <//>

      <!-- BOARD · overview.jsx:233-237 -->
      <${DomainCard} title="보드" linkLabel="보드" nav=${{ tab: 'board' }} testId="domain-board">
        <div class="ov-stat-row"><span class="k">전체 포스트</span><span class="v mono">${boardTotal.value !== null ? boardTotal.value : '—'}</span></div>
      <//>

      <!-- CONNECTORS · overview.jsx:240-249 -->
      <${DomainCard}
        title="커넥터"
        count=${connectorsData ? String(connectorsData.active_count) : undefined}
        tone=${connectorsData ? (connectorsData.active_count > 0 ? 'ok' : 'warn') : undefined}
        linkLabel="커넥터"
        nav=${{ tab: 'connectors' }}
        testId="domain-connectors"
      >
        <div class="ov-mini-list">
          ${connectorsData
            ? connectorsData.connectors.length > 0
              ? connectorsData.connectors.map(c => html`
                  <div class="ov-mini-row" key=${c.connector_id}>
                    <span class="inline-block size-1.5 rounded-full ${c.connected ? 'bg-ok' : 'bg-warning'}"></span>
                    <span class="ov-mini-txt">${c.display_name}</span>
                  </div>
                `)
              : html`<div class="ov-mini-empty ov-empty">등록된 커넥터 없음</div>`
            : html`<div class="ov-mini-empty ov-empty">${connectorsError ? `커넥터 로드 실패: ${connectorsError}` : '커넥터 로드 중'}</div>`}
        </div>
      <//>

      <!-- FLEET summary · overview.jsx:252-260 -->
      <${DomainCard} title="Fleet 요약" linkLabel="Monitor" nav=${{ tab: 'monitoring' }} testId="domain-fleet">
        <div class="ov-fleet-sum">
          <div class="ov-fleet-stat"><span class="v ok">${stats.run}</span><span class="k">실행</span></div>
          <div class="ov-fleet-stat"><span class="v warn">${stats.att}</span><span class="k">주의</span></div>
          <div class="ov-fleet-stat"><span class=${`v ${stats.hot > 0 ? 'bad' : ''}`}>${stats.hot}</span><span class="k">압박</span></div>
          <div class="ov-fleet-stat"><span class="v">${stats.total}</span><span class="k">전체</span></div>
        </div>
        <div class="ov-stat-row"><span class="k">전체 keeper</span><span class="v mono">${stats.total}</span></div>
      <//>
    </div>
  `
}

// ─── Root ────────────────────────────────────────────────────────────────────

export function Overview() {
  useNowSecondsTicker()
  useEffect(() => {
    void loadOverviewTelemetry()
    const interval = window.setInterval(() => {
      void loadOverviewTelemetry()
    }, 60_000)
    return () => window.clearInterval(interval)
  }, [])
  // Gate connectors have no global boot-time fetch (unlike governance/tools
  // below, which app.ts already loads at startup) — this is the only signal
  // on this surface that needs its own fetch trigger.
  useEffect(() => {
    void loadOverviewConnectors()
    const interval = window.setInterval(() => {
      void loadOverviewConnectors()
    }, 60_000)
    return () => window.clearInterval(interval)
  }, [])
  const keeperList = keepers.value
  const goalList = goals.value
  const fusionList = fusionRuns.value
  const approvalQueue = governanceData.value?.approval_queue ?? []
  const stats = useMemo(() => computeOverviewStats(keeperList), [keeperList])
  const digest = useMemo(
    () => computeOverviewDigest(goalList, fusionList, approvalQueue),
    [goalList, fusionList, approvalQueue],
  )
  const telemetry = overviewTelemetryResource.state.value
  const connectors = overviewConnectorsResource.state.value
  const automation = toolsData.value?.scheduled_automation ?? null
  const scheduledPending = scheduledPendingApprovalCount(automation)

  return html`
    <main class="ov v2-overview-surface ss-surface text-text-primary" data-testid="overview-surface">
      <div class="ov-scroll v2-overview-scroll">
        <${OverviewHeader} />
        <${OverviewKpiStrip} stats=${stats} digest=${digest} connectorsData=${connectors.data} scheduledPending=${scheduledPending} />
        <div class="ov-grid v2-overview-primary-grid" data-testid="overview-primary-grid">
          <${OverviewAttentionPanel} keeperList=${keeperList} />
          <${OverviewTelemetry} telemetry=${telemetry} />
        </div>
        <${OverviewDomainSection}
          stats=${stats}
          digest=${digest}
          connectorsData=${connectors.data}
          connectorsError=${connectors.error}
          automation=${automation}
          automationError=${toolsError.value}
          scheduledPending=${scheduledPending}
        />
      </div>
    </main>
  `
}
