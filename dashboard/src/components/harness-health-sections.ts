// Harness health reusable section sub-components.

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { navigate } from '../router'
import { formatTimeAgo, formatTimestampKo } from '../lib/format-time'
import { SurfaceCard } from './common/card'
import { CopyIdButton } from './common/copy-id-button'
import { SectionCap } from './common/section-cap'
import { StatusChip } from './common/status-chip'
import { StatusDot } from './common/status-dot'
import type {
  RailStatus,
  GateDistribution,
  HarnessHealthData,
  HarnessVerdictItem,
  HarnessSignalSection,
  PreCompactEvent,
  HandoffEvent,
} from './harness-health-state'

/**
 * Pure filter for recent verdict rows.
 *
 * Case-insensitive substring match on `task_title`, `task_id`, `agent_name`,
 * `gate`, `evaluator_cascade`, and `verdict` so operators can locate a
 * verdict by any visible identifier.
 *
 * Empty/whitespace query returns the input reference unchanged so
 * `useMemo` keeps referential equality for the non-filtering path.
 *
 * Input is never mutated.
 */
export function filterVerdicts(
  items: readonly HarnessVerdictItem[],
  query: string,
): readonly HarnessVerdictItem[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return items
  return items.filter(item => {
    if (item.task_title && item.task_title.toLowerCase().includes(needle)) return true
    if (item.task_id && item.task_id.toLowerCase().includes(needle)) return true
    if (item.agent_name && item.agent_name.toLowerCase().includes(needle)) return true
    if (item.gate && item.gate.toLowerCase().includes(needle)) return true
    if (item.evaluator_cascade && item.evaluator_cascade.toLowerCase().includes(needle)) return true
    if (item.verdict && item.verdict.toLowerCase().includes(needle)) return true
    return false
  })
}

/**
 * Pure filter for pre-compact events.
 *
 * Case-insensitive substring match on `keeper_name`, `trigger`, `model_family`,
 * and any entry of `strategies`. Empty/whitespace query returns the input
 * reference unchanged so `useMemo` keeps referential equality. Input is
 * never mutated.
 */
export function filterPreCompactEvents(
  items: readonly PreCompactEvent[],
  query: string,
): readonly PreCompactEvent[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return items
  return items.filter(item => {
    if (item.keeper_name && item.keeper_name.toLowerCase().includes(needle)) return true
    if (item.trigger && item.trigger.toLowerCase().includes(needle)) return true
    if (item.model_family && item.model_family.toLowerCase().includes(needle)) return true
    if (item.strategies.some(s => s.toLowerCase().includes(needle))) return true
    return false
  })
}

/**
 * Pure filter for handoff events.
 *
 * Case-insensitive substring match on `keeper_name`, `to_model`, `trace_id`,
 * `prev_trace_id`, and `new_trace_id`. Empty/whitespace query returns the
 * input reference unchanged. Input is never mutated.
 */
export function filterHandoffEvents(
  items: readonly HandoffEvent[],
  query: string,
): readonly HandoffEvent[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return items
  return items.filter(item => {
    if (item.keeper_name && item.keeper_name.toLowerCase().includes(needle)) return true
    if (item.to_model && item.to_model.toLowerCase().includes(needle)) return true
    if (item.trace_id && item.trace_id.toLowerCase().includes(needle)) return true
    if (item.prev_trace_id && item.prev_trace_id.toLowerCase().includes(needle)) return true
    if (item.new_trace_id && item.new_trace_id.toLowerCase().includes(needle)) return true
    return false
  })
}

// ── Helper functions ──

export function railStatusLabel(status: RailStatus): string {
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

export function statusChipClass(status: RailStatus): string {
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

export function statusCardClass(status: RailStatus): string {
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

export const formatTimestamp = formatTimestampKo

export function freshnessLabel(ts: number | null | undefined, fallback = '기록 없음'): string {
  if (ts == null) return fallback
  return formatTimeAgo(ts)
}

export function emptyReasonText(reason?: string | null): string {
  switch (reason) {
    case 'window_empty':
      return '선택된 범위에는 신호가 없습니다.'
    case 'no_recent_events':
      return '기록은 있지만 최근 신호가 없습니다.'
    case 'no_runtime_activity':
    default:
      return '아직 이 감시 채널을 통과한 실행이 없습니다.'
  }
}

export function verdictTone(verdict: string): string {
  return verdict.startsWith('approve')
    ? 'bg-[var(--ok)]'
    : 'bg-[var(--bad)]'
}

export function verdictSummary(verdict: string): string {
  if (!verdict.startsWith('reject:')) return verdict
  return verdict.slice('reject:'.length).trim() || 'reject'
}

export function heroTitle(data: HarnessHealthData): string {
  const statuses = [
    data.overview.evaluator_status,
    data.overview.pre_compact_status,
    data.overview.handoff_status,
  ]
  if (statuses.includes('warning')) return '감시 채널에 주의가 필요합니다.'
  if (statuses.includes('stale')) return '신호는 있지만 최신성이 떨어집니다.'
  if (statuses.every(status => status === 'idle')) return '아직 감시 기록이 없습니다.'
  return '감시 채널이 정상 작동 중입니다.'
}

export function heroBody(data: HarnessHealthData): string {
  if (data.overview.evaluator_status === 'warning') {
    const ratio = Math.round((data.overview.fallback_ratio ?? 0) * 100)
    return `평가 모델의 대체 처리 비중이 ${ratio}%라 판정을 그대로 신뢰하기 어렵습니다.`
  }
  if (data.overview.handoff_status === 'warning') {
    return '세대 교체 기록에 누락 필드가 있어 keeper 연속성 점검이 필요합니다.'
  }
  if (data.overview.pre_compact_status === 'warning') {
    return '압축 직전 컨텍스트 압력이 높아 keeper 연속성이 흔들릴 수 있습니다.'
  }
  if (data.overview.last_signal_at == null) {
    return 'keeper 장기 실행 중 평가, 압축, 세대 교체가 정상인지 감시합니다.'
  }
  return `마지막 안전 신호는 ${freshnessLabel(data.overview.last_signal_at)}에 들어왔습니다.`
}

export function railDetail(data: HarnessHealthData, rail: 'evaluator' | 'pre_compact' | 'handoff'): string {
  if (rail === 'evaluator') {
    if (data.calibration.total_verdicts === 0) return '판정 기록 없음'
    return `판정 ${data.calibration.total_verdicts}건`
  }
  if (rail === 'pre_compact') {
    if (data.overview.latest_pre_compact_ratio == null) return '최근 압축 없음'
    return `컨텍스트 ${Math.round(data.overview.latest_pre_compact_ratio * 100)}%`
  }
  if (data.overview.latest_handoff_generation == null) return '최근 교체 없음'
  return `${data.overview.latest_handoff_generation}세대`
}

export function railFreshness(data: HarnessHealthData, rail: 'evaluator' | 'pre_compact' | 'handoff'): string {
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

// ── Small components ──

export function StatusPill({ status }: { status: RailStatus }) {
  return html`
    <${StatusChip} tone=${statusChipClass(status)} class="font-semibold">${railStatusLabel(status)}<//>
  `
}

export { StatCard } from './common/stat-card'

export function EmptySignal({ text }: { text: string }) {
  return html`
    <div class="rounded border border-dashed border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2 text-sm text-[var(--text-dim)]">
      ${text}
    </div>
  `
}

export function GateChart({ distribution }: { distribution: GateDistribution }) {
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

export function HeroRailCard({
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
    <div class=${`rounded border p-3 ${statusCardClass(status)}`}>
      <div class="flex items-start justify-between gap-3">
        <div class="text-sm font-medium text-[var(--text-strong)]">${label}</div>
        <${StatusPill} status=${status} />
      </div>
      <div class="mt-3 text-lg font-semibold text-[var(--text-body)]">${detail}</div>
      <div class="mt-1 text-xs text-[var(--text-dim)]">최근 신호 ${freshness}</div>
    </div>
  `
}

export function ScopePairing() {
  return html`
    <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
      <${SurfaceCard} variant="compact">
        <div class="flex flex-col gap-2">
          <div class="flex items-center justify-between gap-3">
            <div>
              <${SectionCap}>실험 루프<//>
              <div class="mt-1 text-sm font-medium text-[var(--text-strong)]">오토리서치가 답하는 것</div>
            </div>
            <button type="button"
              class="rounded border border-[var(--white-8)] px-2.5 py-1 text-2xs text-[var(--text-muted)] transition-colors hover:border-[var(--ok-30)] hover:text-[var(--text-body)]"
              onClick=${() => navigate('lab', { section: 'autoresearch' })}
            >오토리서치 열기</button>
          </div>
          <div class="text-sm leading-loose text-[var(--text-body)]">
            어떤 파일을 어떻게 바꿔 어떤 metric을 밀어 올리려는지, 그리고 cycle별 keep/discard가 어땠는지 봅니다.
          </div>
        </div>
      <//>

      <${SurfaceCard} variant="compact">
        <div class="flex flex-col gap-2">
          <${SectionCap}>안전 감시<//>
          <div class="text-sm font-medium text-[var(--text-strong)]">하네스가 답하는 것</div>
          <div class="text-sm leading-loose text-[var(--text-body)]">
            평가 모델이 건강한지, 장기 실행 중 압축이 정상인지, 세대 교체가 안전한지 봅니다.
          </div>
        </div>
      <//>
    </div>
  `
}

export function RailHeader({
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
        <div class="mt-1 text-sm leading-loose text-[var(--text-muted)]">${description}</div>
      </div>
      <div class="text-xs text-[var(--text-dim)]">최근 신호 ${freshnessLabel(lastEventAt)}</div>
    </div>
  `
}

// ── Section components ──

export function RecentVerdictsList({ items }: { items: HarnessVerdictItem[] }) {
  const query = useSignal('')
  const visibleItems = useMemo(
    () => filterVerdicts(items, query.value),
    [items, query.value],
  )
  const isFiltering = query.value.trim() !== ''

  if (items.length === 0) {
    return html`<${EmptySignal} text="최근 평가 판정이 없습니다." />`
  }

  return html`
    <div class="space-y-2">
      <div class="flex justify-end">
        <input
          type="search"
          value=${query.value}
          placeholder="task / agent / gate / cascade 필터"
          aria-label="판정 필터"
          onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
          class="min-w-40 max-w-65 flex-1 rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-2xs text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)]"
        />
      </div>
      ${isFiltering && visibleItems.length === 0
        ? html`<div class="py-4 text-center text-2xs text-[var(--text-dim)]">필터 결과 없음 (${items.length} items)</div>`
        : visibleItems.map(item => html`
          <div class="rounded border border-[var(--white-8)] bg-[var(--white-4)] p-3">
            <div class="flex items-start justify-between gap-3">
              <div>
                <div class="text-sm font-medium text-[var(--text-strong)]">${item.task_title || item.task_id}</div>
                <div class="mt-1 text-xs text-[var(--text-muted)]">
                  ${item.agent_name || 'agent'} · ${item.gate || 'gate'} · ${item.evaluator_cascade || 'cascade'} · ${formatTimestamp(item.timestamp)}
                </div>
              </div>
              <${StatusDot} size="md" class=${verdictTone(item.verdict)} />
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

export function PreCompactList({ section }: { section: HarnessSignalSection<PreCompactEvent> }) {
  const query = useSignal('')
  const visibleItems = useMemo(
    () => filterPreCompactEvents(section.recent_events, query.value),
    [section.recent_events, query.value],
  )
  const isFiltering = query.value.trim() !== ''

  if (section.recent_events.length === 0) {
    return html`<${EmptySignal} text=${emptyReasonText(section.empty_reason)} />`
  }

  return html`
    <div class="space-y-2">
      <div class="flex justify-end">
        <input
          type="search"
          value=${query.value}
          placeholder="keeper / trigger / model / strategy 필터"
          aria-label="압축 이벤트 필터"
          onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
          class="min-w-40 max-w-65 flex-1 rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-2xs text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)]"
        />
      </div>
      ${isFiltering && visibleItems.length === 0
        ? html`<div class="py-4 text-center text-2xs text-[var(--text-dim)]">필터 결과 없음 (${section.recent_events.length} items)</div>`
        : visibleItems.map(item => html`
          <div class="rounded border border-[var(--white-8)] bg-[var(--white-4)] p-3">
            <div class="flex items-start justify-between gap-3">
              <div class="text-sm font-medium text-[var(--text-strong)]">${item.keeper_name}</div>
              <div class="text-xs text-[var(--text-muted)]">${formatTimestamp(item.timestamp)}</div>
            </div>
            <div class="mt-2 grid grid-cols-2 gap-2 text-xs text-[var(--text-body)]">
              <span>컨텍스트 ${Math.round(item.context_ratio * 100)}%</span>
              <span>메시지 ${item.message_count}건</span>
              <span>토큰 ${item.token_count.toLocaleString()}</span>
              <span>${item.model_family || '모델 미확인'}</span>
            </div>
            <div class="mt-2 text-xs text-[var(--text-muted)]">${item.trigger}</div>
            ${item.strategies.length > 0 ? html`
              <div class="mt-2 flex flex-wrap gap-1">
                ${item.strategies.map(strategy => html`
                  <span class="rounded-sm border border-[var(--white-8)] px-2 py-0.5 text-3xs text-[var(--text-muted)]">${strategy}</span>
                `)}
              </div>
            ` : null}
          </div>
        `)}
    </div>
  `
}

export function HandoffList({ section }: { section: HarnessSignalSection<HandoffEvent> }) {
  const query = useSignal('')
  const visibleItems = useMemo(
    () => filterHandoffEvents(section.recent_events, query.value),
    [section.recent_events, query.value],
  )
  const isFiltering = query.value.trim() !== ''

  if (section.recent_events.length === 0) {
    return html`<${EmptySignal} text=${emptyReasonText(section.empty_reason)} />`
  }

  return html`
    <div class="space-y-2">
      <div class="flex justify-end">
        <input
          type="search"
          value=${query.value}
          placeholder="keeper / model / trace_id 필터"
          aria-label="세대 교체 필터"
          onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
          class="min-w-40 max-w-65 flex-1 rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-2xs text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)]"
        />
      </div>
      ${isFiltering && visibleItems.length === 0
        ? html`<div class="py-4 text-center text-2xs text-[var(--text-dim)]">필터 결과 없음 (${section.recent_events.length} items)</div>`
        : visibleItems.map(item => html`
          <div class="rounded border border-[var(--white-8)] bg-[var(--white-4)] p-3">
            <div class="flex items-start justify-between gap-3">
              <div class="text-sm font-medium text-[var(--text-strong)]">${item.keeper_name}</div>
              <div class="text-xs text-[var(--text-muted)]">${formatTimestamp(item.timestamp)}</div>
            </div>
            <div class="mt-2 grid grid-cols-2 gap-2 text-xs text-[var(--text-body)]">
              <span>${item.generation}세대</span>
              <span>다음 ${item.next_generation ?? '-'}세대</span>
              <span class="inline-flex items-center gap-1">
                <span class="font-mono" title=${item.trace_id}>${item.trace_id.slice(0, 8)}</span>
                <${CopyIdButton} value=${item.trace_id} label="trace_id" size=${10} />
              </span>
              <span>${item.to_model ?? '모델 미확인'}</span>
            </div>
            ${item.prev_trace_id ? html`
              <div class="mt-2 text-xs text-[var(--text-muted)]">이전 ${item.prev_trace_id.slice(0, 8)} → 새 ${item.new_trace_id?.slice(0, 8) ?? '-'}</div>
            ` : null}
          </div>
        `)}
    </div>
  `
}
