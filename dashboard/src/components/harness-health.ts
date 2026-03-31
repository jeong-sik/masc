// Safety Harness panel — evaluator calibration and long-running runtime rails.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { get } from '../api/core'
import { createAsyncResource, loaded, type AsyncResource } from '../lib/async-state'
import { lastEvent } from '../sse'
import { navigate } from '../router'
import { formatTimeAgo, formatTimestampKo } from '../lib/format-time'
import { Card, SurfaceCard } from './common/card'

type RailStatus = 'healthy' | 'warning' | 'stale' | 'idle'

interface GateDistribution {
  [gate: string]: number
}

interface CalibrationStats {
  total_verdicts: number
  approve_count: number
  reject_count: number
  gate_distribution: GateDistribution
  labeled_count: number
  false_positive_count: number
  false_negative_count: number
  agreement_rate: number
  fallback_count?: number
  recent_fallback_reasons?: string[]
}

interface HarnessOverview {
  evaluator_status: RailStatus
  pre_compact_status: RailStatus
  handoff_status: RailStatus
  last_signal_at: number | null
  evaluator_last_event_at: number | null
  pre_compact_last_event_at: number | null
  handoff_last_event_at: number | null
  fallback_ratio: number
  latest_pre_compact_ratio: number | null
  latest_handoff_generation: number | null
}

interface HarnessVerdictItem {
  timestamp: number
  task_id: string
  task_title: string
  agent_name: string
  gate: string
  verdict: string
  evaluator_cascade: string
  fallback_reason?: string | null
}

interface PreCompactEvent {
  timestamp: number
  keeper_name: string
  context_ratio: number
  message_count: number
  token_count: number
  strategies: string[]
  model_family: string
  trigger: string
}

interface HandoffEvent {
  timestamp: number
  keeper_name: string
  trace_id: string
  generation: number
  next_generation: number | null
  prev_trace_id: string | null
  new_trace_id: string | null
  to_model: string | null
}

interface HarnessSignalSection<T> {
  description: string
  recent_events: T[]
  total_recent: number
  status: RailStatus
  last_event_at: number | null
  empty_reason?: string | null
}

interface HarnessHealthData {
  generated_at: number
  scope_note: string
  overview: HarnessOverview
  calibration: CalibrationStats
  recent_verdicts: HarnessVerdictItem[]
  pre_compact: HarnessSignalSection<PreCompactEvent>
  recent_handoffs: HarnessSignalSection<HandoffEvent>
}

const HARNESS_RELOAD_DEBOUNCE_MS = 700

const harness: AsyncResource<HarnessHealthData> = createAsyncResource()
let reloadTimer: ReturnType<typeof setTimeout> | null = null

function clearHarnessReloadTimer(): void {
  if (reloadTimer) {
    clearTimeout(reloadTimer)
    reloadTimer = null
  }
}

function scheduleHarnessReload(): void {
  clearHarnessReloadTimer()
  reloadTimer = setTimeout(() => {
    void loadHarnessHealth()
  }, HARNESS_RELOAD_DEBOUNCE_MS)
}
export function resetHarnessHealthState(): void {
  harness.reset()
  clearHarnessReloadTimer()
}

function loadHarnessHealth(): Promise<void> {
  return harness.load(() => get<HarnessHealthData>('/api/v1/dashboard/harness-health'))
}

export async function refreshHarnessSurface(): Promise<void> {
  await loadHarnessHealth()
}

function mergeRecent<T>(
  current: T[],
  nextItem: T,
  isSame: (left: T, right: T) => boolean,
  maxItems: number,
) {
  const filtered = current.filter(item => !isSame(item, nextItem))
  return [nextItem, ...filtered].slice(0, maxItems)
}

function updateHarnessData(
  update: (data: HarnessHealthData) => HarnessHealthData,
): void {
  const s = harness.state.value
  if (s.status !== 'loaded') return
  harness.state.value = loaded(update(s.data))
}

function statusLabel(status: RailStatus): string {
  switch (status) {
    case 'healthy':
      return '정상'
    case 'warning':
      return '주의'
    case 'stale':
      return '오래됨'
    case 'idle':
    default:
      return '대기'
  }
}

function statusChipClass(status: RailStatus): string {
  switch (status) {
    case 'healthy':
      return 'border-[var(--ok-30)] bg-[var(--ok-12)] text-[var(--ok)]'
    case 'warning':
      return 'border-[var(--warn-30)] bg-[var(--warn-12)] text-[var(--warn)]'
    case 'stale':
      return 'border-[var(--white-12)] bg-[var(--white-4)] text-[var(--text-muted)]'
    case 'idle':
    default:
      return 'border-[var(--white-8)] bg-[var(--white-4)] text-[var(--text-dim)]'
  }
}

function statusCardClass(status: RailStatus): string {
  switch (status) {
    case 'healthy':
      return 'border-[var(--ok-30)] bg-[var(--ok-12)]'
    case 'warning':
      return 'border-[var(--warn-30)] bg-[var(--warn-12)]'
    case 'stale':
      return 'border-[var(--white-12)] bg-[var(--white-4)]'
    case 'idle':
    default:
      return 'border-[var(--white-8)] bg-[var(--white-4)]'
  }
}

const formatTimestamp = formatTimestampKo

function freshnessLabel(ts: number | null | undefined, fallback = '기록 없음'): string {
  if (ts == null) return fallback
  return formatTimeAgo(ts)
}

function emptyReasonText(reason?: string | null): string {
  switch (reason) {
    case 'window_empty':
      return '선택된 범위에는 신호가 없습니다.'
    case 'no_recent_events':
      return '기록은 있지만 최근 신호가 없습니다.'
    case 'no_runtime_activity':
    default:
      return '아직 이 rail을 통과한 실행이 없습니다.'
  }
}

function verdictTone(verdict: string): string {
  return verdict.startsWith('approve')
    ? 'bg-[var(--ok)]'
    : 'bg-[var(--bad)]'
}

function verdictSummary(verdict: string): string {
  if (!verdict.startsWith('reject:')) return verdict
  return verdict.slice('reject:'.length).trim() || 'reject'
}

function heroTitle(data: HarnessHealthData): string {
  const statuses = [
    data.overview.evaluator_status,
    data.overview.pre_compact_status,
    data.overview.handoff_status,
  ]
  if (statuses.includes('warning')) return '실험 기계에 주의가 필요합니다.'
  if (statuses.includes('stale')) return '신호는 있지만 최신성이 떨어집니다.'
  if (statuses.every(status => status === 'idle')) return '아직 안전 rail 기록이 없습니다.'
  return '실험 기계는 현재 안정적입니다.'
}

function heroBody(data: HarnessHealthData): string {
  if (data.overview.evaluator_status === 'warning') {
    const ratio = Math.round((data.overview.fallback_ratio ?? 0) * 100)
    return `Evaluator fallback 비중이 ${ratio}%라 verdict를 그대로 신뢰하기 어렵습니다.`
  }
  if (data.overview.handoff_status === 'warning') {
    return 'Handoff 기록에 누락 필드가 있어 keeper continuity 점검이 필요합니다.'
  }
  if (data.overview.pre_compact_status === 'warning') {
    return 'Compaction 직전 컨텍스트 압력이 높아 keeper continuity가 흔들릴 수 있습니다.'
  }
  if (data.overview.last_signal_at == null) {
    return 'Autoresearch는 cycle outcome을 보고, Harness는 evaluator와 continuity rail의 건강도를 봅니다.'
  }
  return `마지막 안전 신호는 ${freshnessLabel(data.overview.last_signal_at)}에 들어왔습니다.`
}

function railDetail(data: HarnessHealthData, rail: 'evaluator' | 'pre_compact' | 'handoff'): string {
  if (rail === 'evaluator') {
    if (data.calibration.total_verdicts === 0) return 'verdict 기록 없음'
    return `${data.calibration.total_verdicts} verdict`
  }
  if (rail === 'pre_compact') {
    if (data.overview.latest_pre_compact_ratio == null) return '최근 compaction 없음'
    return `ratio ${data.overview.latest_pre_compact_ratio.toFixed(2)}`
  }
  if (data.overview.latest_handoff_generation == null) return '최근 handoff 없음'
  return `generation ${data.overview.latest_handoff_generation}`
}

function railFreshness(data: HarnessHealthData, rail: 'evaluator' | 'pre_compact' | 'handoff'): string {
  switch (rail) {
    case 'evaluator':
      return freshnessLabel(data.overview.evaluator_last_event_at, '기록 없음')
    case 'pre_compact':
      return freshnessLabel(data.overview.pre_compact_last_event_at, '기록 없음')
    case 'handoff':
    default:
      return freshnessLabel(data.overview.handoff_last_event_at, '기록 없음')
  }
}

function handleHarnessSSE(): void {
  const evt = lastEvent.value
  if (!evt) return
  const type = evt.type ?? ''
  const payload = (evt as unknown as { payload?: Record<string, unknown> }).payload
  if (!payload) return

  if (type === 'oas:masc:harness:verdict_recorded') {
    const nextItem: HarnessVerdictItem = {
      timestamp:
        typeof payload.timestamp === 'number'
          ? payload.timestamp
          : Date.now() / 1000,
      task_id: String(payload.task_id ?? ''),
      task_title: String(payload.task_title ?? 'task'),
      agent_name: String(payload.agent_name ?? ''),
      gate: String(payload.gate ?? ''),
      verdict: String(payload.verdict ?? ''),
      evaluator_cascade: String(payload.evaluator_cascade ?? ''),
      fallback_reason:
        payload.fallback_reason == null ? null : String(payload.fallback_reason),
    }
    updateHarnessData(data => ({
      ...data,
      recent_verdicts: mergeRecent(
        data.recent_verdicts,
        nextItem,
        (left, right) =>
          left.timestamp === right.timestamp
          && left.task_id === right.task_id
          && left.verdict === right.verdict,
        8,
      ),
      overview: {
        ...data.overview,
        last_signal_at: nextItem.timestamp,
        evaluator_last_event_at: nextItem.timestamp,
      },
    }))
    scheduleHarnessReload()
  }

  if (type === 'oas:masc:harness:pre_compact') {
    const nextItem: PreCompactEvent = {
      timestamp:
        typeof payload.timestamp === 'number'
          ? payload.timestamp
          : Date.now() / 1000,
      keeper_name: String(payload.keeper_name ?? ''),
      context_ratio: Number(payload.context_ratio ?? 0),
      message_count: Number(payload.message_count ?? 0),
      token_count: Number(payload.token_count ?? 0),
      strategies: Array.isArray(payload.strategies)
        ? payload.strategies.map(value => String(value))
        : [],
      model_family: String(payload.model_family ?? ''),
      trigger: String(payload.trigger ?? ''),
    }
    updateHarnessData(data => ({
      ...data,
      pre_compact: {
        ...data.pre_compact,
        recent_events: mergeRecent(
          data.pre_compact.recent_events,
          nextItem,
          (left, right) =>
            left.timestamp === right.timestamp
            && left.keeper_name === right.keeper_name
            && left.trigger === right.trigger,
          8,
        ),
        total_recent: data.pre_compact.total_recent + 1,
        last_event_at: nextItem.timestamp,
        empty_reason: null,
      },
      overview: {
        ...data.overview,
        last_signal_at: nextItem.timestamp,
        pre_compact_last_event_at: nextItem.timestamp,
        latest_pre_compact_ratio: nextItem.context_ratio,
      },
    }))
    scheduleHarnessReload()
  }

  if (type === 'oas:masc:harness:handoff') {
    const nextItem: HandoffEvent = {
      timestamp:
        typeof payload.timestamp === 'number'
          ? payload.timestamp
          : Date.now() / 1000,
      keeper_name: String(payload.keeper_name ?? ''),
      trace_id: String(payload.trace_id ?? ''),
      generation: Number(payload.generation ?? 0),
      next_generation:
        payload.next_generation == null ? null : Number(payload.next_generation),
      prev_trace_id:
        payload.prev_trace_id == null ? null : String(payload.prev_trace_id),
      new_trace_id:
        payload.new_trace_id == null ? null : String(payload.new_trace_id),
      to_model:
        payload.to_model == null ? null : String(payload.to_model),
    }
    updateHarnessData(data => ({
      ...data,
      recent_handoffs: {
        ...data.recent_handoffs,
        recent_events: mergeRecent(
          data.recent_handoffs.recent_events,
          nextItem,
          (left, right) =>
            left.timestamp === right.timestamp
            && left.trace_id === right.trace_id,
          8,
        ),
        total_recent: data.recent_handoffs.total_recent + 1,
        last_event_at: nextItem.timestamp,
        empty_reason: null,
      },
      overview: {
        ...data.overview,
        last_signal_at: nextItem.timestamp,
        handoff_last_event_at: nextItem.timestamp,
        latest_handoff_generation: nextItem.next_generation ?? nextItem.generation,
      },
    }))
    scheduleHarnessReload()
  }
}

function StatusPill({ status }: { status: RailStatus }) {
  return html`
    <span class=${`inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${statusChipClass(status)}`}>
      ${statusLabel(status)}
    </span>
  `
}

function StatCard({ label, value, sub }: { label: string; value: string | number; sub?: string }) {
  return html`
    <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3 text-center">
      <div class="text-2xl font-bold text-[var(--accent)]">${value}</div>
      <div class="mt-1 text-xs text-[var(--text-muted)]">${label}</div>
      ${sub ? html`<div class="mt-0.5 text-xs text-[var(--text-dim)]">${sub}</div>` : null}
    </div>
  `
}

function EmptySignal({ text }: { text: string }) {
  return html`
    <div class="rounded-lg border border-dashed border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2 text-sm text-[var(--text-dim)]">
      ${text}
    </div>
  `
}

function GateChart({ distribution }: { distribution: GateDistribution }) {
  const entries = Object.entries(distribution).sort((a, b) => b[1] - a[1])
  const max = entries[0]?.[1] ?? 1
  if (entries.length === 0) {
    return html`<${EmptySignal} text="아직 verdict 기록이 없습니다." />`
  }
  return html`
    <div class="space-y-2">
      ${entries.map(([gate, count]) => html`
        <div class="flex items-center gap-2">
          <span class="w-20 text-right font-mono text-xs text-[var(--text-muted)]">${gate}</span>
          <div class="h-4 flex-1 overflow-hidden rounded bg-[var(--white-6)]">
            <div
              class="h-full rounded opacity-80 transition-all"
              style=${{ width: `${(count / max) * 100}%`, background: 'var(--accent)' }}
            />
          </div>
          <span class="w-8 text-right text-xs text-[var(--text-body)]">${count}</span>
        </div>
      `)}
    </div>
  `
}

function HeroRailCard({
  label,
  status,
  detail,
  freshness,
}: {
  label: string
  status: RailStatus
  detail: string
  freshness: string
}) {
  return html`
    <div class=${`rounded-xl border p-3 ${statusCardClass(status)}`}>
      <div class="flex items-start justify-between gap-3">
        <div class="text-sm font-medium text-[var(--text-strong)]">${label}</div>
        <${StatusPill} status=${status} />
      </div>
      <div class="mt-3 text-lg font-semibold text-[var(--text-body)]">${detail}</div>
      <div class="mt-1 text-xs text-[var(--text-dim)]">최근 신호 ${freshness}</div>
    </div>
  `
}

function ScopePairing() {
  return html`
    <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
      <${SurfaceCard} variant="compact">
        <div class="flex flex-col gap-2">
          <div class="flex items-center justify-between gap-3">
            <div>
              <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">Generator Loop</div>
              <div class="mt-1 text-sm font-medium text-[var(--text-strong)]">Autoresearch가 답하는 것</div>
            </div>
            <button
              type="button"
              class="rounded border border-[var(--white-8)] px-2.5 py-1 text-[11px] text-[var(--text-muted)] transition-colors hover:border-[var(--ok-30)] hover:text-[var(--text-body)]"
              onClick=${() => navigate('lab', { section: 'autoresearch' })}
            >오토리서치 열기</button>
          </div>
          <div class="text-sm leading-[1.6] text-[var(--text-body)]">
            어떤 파일을 어떻게 바꿔 어떤 metric을 밀어 올리려는지, 그리고 cycle별 keep/discard가 어땠는지 봅니다.
          </div>
        </div>
      <//>

      <${SurfaceCard} variant="compact">
        <div class="flex flex-col gap-2">
          <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">Safety Rails</div>
          <div class="text-sm font-medium text-[var(--text-strong)]">Harness가 답하는 것</div>
          <div class="text-sm leading-[1.6] text-[var(--text-body)]">
            evaluator가 건강한지, 장기 keeper turn에서 compaction이 어떻게 걸리는지, handoff가 정상인지 봅니다.
          </div>
        </div>
      <//>
    </div>
  `
}

function RailHeader({
  title,
  description,
  status,
  lastEventAt,
}: {
  title: string
  description: string
  status: RailStatus
  lastEventAt: number | null
}) {
  return html`
    <div class="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
      <div>
        <div class="flex items-center gap-2">
          <div class="text-sm font-medium text-[var(--text-strong)]">${title}</div>
          <${StatusPill} status=${status} />
        </div>
        <div class="mt-1 text-sm leading-[1.6] text-[var(--text-muted)]">${description}</div>
      </div>
      <div class="text-xs text-[var(--text-dim)]">최근 신호 ${freshnessLabel(lastEventAt)}</div>
    </div>
  `
}

function RecentVerdictsList({ items }: { items: HarnessVerdictItem[] }) {
  if (items.length === 0) {
    return html`<${EmptySignal} text="최근 evaluator verdict가 없습니다." />`
  }

  return html`
    <div class="space-y-2">
      ${items.map(item => html`
        <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
          <div class="flex items-start justify-between gap-3">
            <div>
              <div class="text-sm font-medium text-[var(--text-strong)]">${item.task_title || item.task_id}</div>
              <div class="mt-1 text-xs text-[var(--text-muted)]">
                ${item.agent_name || 'agent'} · ${item.gate || 'gate'} · ${item.evaluator_cascade || 'cascade'} · ${formatTimestamp(item.timestamp)}
              </div>
            </div>
            <span class=${`inline-block h-2.5 w-2.5 rounded-full ${verdictTone(item.verdict)}`} />
          </div>
          <div class="mt-2 text-sm text-[var(--text-body)]">${verdictSummary(item.verdict)}</div>
          ${item.fallback_reason ? html`
            <div class="mt-2 break-all text-xs text-[var(--warn)]">${item.fallback_reason}</div>
          ` : null}
        </div>
      `)}
    </div>
  `
}

function PreCompactList({ section }: { section: HarnessSignalSection<PreCompactEvent> }) {
  if (section.recent_events.length === 0) {
    return html`<${EmptySignal} text=${emptyReasonText(section.empty_reason)} />`
  }

  return html`
    <div class="space-y-2">
      ${section.recent_events.map(item => html`
        <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
          <div class="flex items-start justify-between gap-3">
            <div class="text-sm font-medium text-[var(--text-strong)]">${item.keeper_name}</div>
            <div class="text-xs text-[var(--text-muted)]">${formatTimestamp(item.timestamp)}</div>
          </div>
          <div class="mt-2 grid grid-cols-2 gap-2 text-xs text-[var(--text-body)]">
            <span>ratio ${item.context_ratio.toFixed(3)}</span>
            <span>messages ${item.message_count}</span>
            <span>tokens ${item.token_count}</span>
            <span>${item.model_family || 'model 미상'}</span>
          </div>
          <div class="mt-2 text-xs text-[var(--text-muted)]">${item.trigger}</div>
          ${item.strategies.length > 0 ? html`
            <div class="mt-2 flex flex-wrap gap-1">
              ${item.strategies.map(strategy => html`
                <span class="rounded-full border border-[var(--white-8)] px-2 py-0.5 text-[10px] text-[var(--text-muted)]">${strategy}</span>
              `)}
            </div>
          ` : null}
        </div>
      `)}
    </div>
  `
}

function HandoffList({ section }: { section: HarnessSignalSection<HandoffEvent> }) {
  if (section.recent_events.length === 0) {
    return html`<${EmptySignal} text=${emptyReasonText(section.empty_reason)} />`
  }

  return html`
    <div class="space-y-2">
      ${section.recent_events.map(item => html`
        <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
          <div class="flex items-start justify-between gap-3">
            <div class="text-sm font-medium text-[var(--text-strong)]">${item.keeper_name}</div>
            <div class="text-xs text-[var(--text-muted)]">${formatTimestamp(item.timestamp)}</div>
          </div>
          <div class="mt-2 grid grid-cols-2 gap-2 text-xs text-[var(--text-body)]">
            <span>generation ${item.generation}</span>
            <span>next ${item.next_generation ?? '-'}</span>
            <span class="font-mono">${item.trace_id.slice(0, 8)}</span>
            <span>${item.to_model ?? 'model 미상'}</span>
          </div>
          ${item.prev_trace_id ? html`
            <div class="mt-2 text-xs text-[var(--text-muted)]">prev ${item.prev_trace_id.slice(0, 8)} -> new ${item.new_trace_id?.slice(0, 8) ?? '-'}</div>
          ` : null}
        </div>
      `)}
    </div>
  `
}

export function HarnessHealth() {
  useEffect(() => {
    void loadHarnessHealth()
    return () => {
      clearHarnessReloadTimer()
    }
  }, [])
  useEffect(handleHarnessSSE, [lastEvent.value])

  const s = harness.state.value
  const data = s.status === 'loaded' ? s.data : undefined
  const cal = data?.calibration
  const rejectRate = cal && cal.total_verdicts > 0
    ? ((cal.reject_count / cal.total_verdicts) * 100).toFixed(1)
    : '0'
  const agreementPct = cal ? (cal.agreement_rate * 100).toFixed(1) : '-'
  const fallbackCount = cal?.fallback_count ?? 0
  const fallbackPct = data ? Math.round((data.overview.fallback_ratio ?? 0) * 100) : 0
  const fallbackReasons = cal?.recent_fallback_reasons ?? []

  return html`
    <div class="space-y-4">
      <${Card} title="Safety Harness" class="section">
        ${s.status === 'loading' || s.status === 'idle' ? html`
          <div class="text-sm text-[var(--text-dim)]">로딩 중...</div>
        ` : s.status === 'error' ? html`
          <div class="text-sm text-[var(--bad)]">${s.message}</div>
        ` : !data ? html`
          <${EmptySignal} text="Harness 데이터가 없습니다." />
        ` : html`
          <div class="space-y-4">
            <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-4)] p-4">
              <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                <div class="max-w-3xl">
                  <div class="text-[10px] uppercase tracking-[0.18em] text-[var(--text-muted)]">Can I Trust The Experiment Machinery?</div>
                  <div class="mt-2 text-2xl font-semibold text-[var(--text-strong)]">${heroTitle(data)}</div>
                  <div class="mt-2 text-sm leading-[1.7] text-[var(--text-body)]">${heroBody(data)}</div>
                </div>
                <div class="flex items-center gap-2">
                  <button
                    type="button"
                    class="rounded border border-[var(--white-8)] px-2.5 py-1 text-[11px] text-[var(--text-muted)] transition-colors hover:border-[var(--accent)] hover:text-[var(--text-body)]"
                    onClick=${() => { void loadHarnessHealth() }}
                  >새로고침</button>
                  <button
                    type="button"
                    class="rounded border border-[var(--white-8)] px-2.5 py-1 text-[11px] text-[var(--text-muted)] transition-colors hover:border-[var(--ok-30)] hover:text-[var(--text-body)]"
                    onClick=${() => navigate('lab', { section: 'autoresearch' })}
                  >오토리서치 보기</button>
                </div>
              </div>

              <div class="mt-4 grid grid-cols-1 gap-3 md:grid-cols-3">
                <${HeroRailCard}
                  label="Evaluator"
                  status=${data.overview.evaluator_status}
                  detail=${railDetail(data, 'evaluator')}
                  freshness=${railFreshness(data, 'evaluator')}
                />
                <${HeroRailCard}
                  label="Pre-Compaction"
                  status=${data.overview.pre_compact_status}
                  detail=${railDetail(data, 'pre_compact')}
                  freshness=${railFreshness(data, 'pre_compact')}
                />
                <${HeroRailCard}
                  label="Handoff"
                  status=${data.overview.handoff_status}
                  detail=${railDetail(data, 'handoff')}
                  freshness=${railFreshness(data, 'handoff')}
                />
              </div>

              <div class="mt-4 text-xs text-[var(--text-dim)]">
                generated ${formatTimestamp(data.generated_at)} · 마지막 안전 신호 ${freshnessLabel(data.overview.last_signal_at)}
              </div>
            </div>

            <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] px-4 py-3 text-sm leading-[1.7] text-[var(--text-body)]">
              ${data.scope_note}
            </div>

            <${ScopePairing} />
          </div>
        `}
      <//>

      <${Card} title="Evaluator Calibration" class="section">
        ${!data || !cal ? html`
          <${EmptySignal} text="Evaluator calibration 데이터가 없습니다." />
        ` : html`
          <div class="space-y-4">
            <${RailHeader}
              title="Judge of the Judge"
              description="실험 cycle 자체가 아니라, verdict 기계가 얼마나 건강하게 작동하는지 봅니다."
              status=${data.overview.evaluator_status}
              lastEventAt=${data.overview.evaluator_last_event_at}
            />

            ${fallbackPct > 80 ? html`
              <div class="rounded-lg border border-[var(--warn-30)] bg-[var(--warn-12)] px-4 py-3">
                <div class="mb-1 text-sm font-medium text-[var(--warn)]">Evaluator 미연결</div>
                <div class="text-xs text-[var(--warn)]">
                  전체 ${cal.total_verdicts}건 중 ${fallbackCount}건이 fallback으로 처리됐습니다.
                  지금은 LLM evaluator보다 fallback gate가 더 많이 작동합니다.
                </div>
                ${fallbackReasons.length > 0 ? html`
                  <details class="mt-2">
                    <summary class="cursor-pointer text-xs text-[var(--warn)] opacity-70">최근 에러 (${fallbackReasons.length}건)</summary>
                    <div class="mt-1 space-y-1">
                      ${fallbackReasons.map(reason => html`
                        <div class="break-all font-mono text-xs text-[var(--warn)] opacity-70">${reason}</div>
                      `)}
                    </div>
                  </details>
                ` : null}
              </div>
            ` : null}

            <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <${StatCard} label="총 Verdict" value=${cal.total_verdicts} />
              <${StatCard} label="Reject 비율" value="${rejectRate}%" />
              <${StatCard} label="Fallback 비율" value="${fallbackPct}%" />
              <${StatCard}
                label="일치율"
                value="${agreementPct}%"
                sub="FP:${cal.false_positive_count} FN:${cal.false_negative_count}"
              />
            </div>

            <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-3)] p-3 text-xs leading-[1.6] text-[var(--text-muted)]">
              인간 라벨 ${cal.labeled_count}건이 calibration ground truth입니다. 값이 0이면 runtime health는 볼 수 있어도 evaluator accuracy는 아직 검증되지 않았습니다.
            </div>

            <div>
              <div class="mb-2 text-xs uppercase tracking-wider text-[var(--text-dim)]">Gate 분포</div>
              <${GateChart} distribution=${cal.gate_distribution} />
            </div>

            <div>
              <div class="mb-2 text-xs uppercase tracking-wider text-[var(--text-dim)]">최근 Verdict</div>
              <${RecentVerdictsList} items=${data.recent_verdicts} />
            </div>
          </div>
        `}
      <//>

      <${Card} title="Pre-Compaction Rail" class="section">
        ${!data ? html`
          <${EmptySignal} text="Pre-compaction 데이터가 없습니다." />
        ` : html`
          <div class="space-y-4">
            <${RailHeader}
              title="Continuity Pressure"
              description=${data.pre_compact.description}
              status=${data.pre_compact.status}
              lastEventAt=${data.pre_compact.last_event_at}
            />
            <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
              <${StatCard}
                label="최근 ratio"
                value=${data.overview.latest_pre_compact_ratio != null ? data.overview.latest_pre_compact_ratio.toFixed(2) : '-'}
                sub=${`최근 ${data.pre_compact.total_recent}건`}
              />
              <${StatCard}
                label="최근 freshness"
                value=${freshnessLabel(data.pre_compact.last_event_at)}
              />
              <${StatCard}
                label="status"
                value=${statusLabel(data.pre_compact.status)}
              />
            </div>
            <${PreCompactList} section=${data.pre_compact} />
          </div>
        `}
      <//>

      <${Card} title="Handoff Rail" class="section">
        ${!data ? html`
          <${EmptySignal} text="Handoff 데이터가 없습니다." />
        ` : html`
          <div class="space-y-4">
            <${RailHeader}
              title="Keeper Handoff"
              description=${data.recent_handoffs.description}
              status=${data.recent_handoffs.status}
              lastEventAt=${data.recent_handoffs.last_event_at}
            />
            <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
              <${StatCard}
                label="최근 generation"
                value=${data.overview.latest_handoff_generation != null ? data.overview.latest_handoff_generation : '-'}
                sub=${`최근 ${data.recent_handoffs.total_recent}건`}
              />
              <${StatCard}
                label="최근 freshness"
                value=${freshnessLabel(data.recent_handoffs.last_event_at)}
              />
              <${StatCard}
                label="status"
                value=${statusLabel(data.recent_handoffs.status)}
              />
            </div>
            <${HandoffList} section=${data.recent_handoffs} />
          </div>
        `}
      <//>
    </div>
  `
}
