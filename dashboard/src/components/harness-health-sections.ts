// Harness health reusable section sub-components.

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { formatTimeAgo, formatTimestampKo } from '../lib/format-time'
import { assertExhaustive } from '../lib/exhaustive'
import { SurfaceCard } from './common/card'
import { CopyIdButton } from './common/copy-id-button'
import { TextInput } from './common/input'
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
import { verdictWithoutRejectPrefix, verdictToneClass, railStatusMessage } from '../lib/keeper-classifiers'

function ItemTitle({ children, class: cx }: { children: unknown; class?: string }) {
  return html`<div class=${`text-sm font-medium text-[var(--color-fg-secondary)] ${cx ?? ''}`}>${children}</div>
  `
}

/**
 * Pure filter for recent verdict rows.
 *
 * Case-insensitive substring match on `task_title`, `task_id`, `agent_name`,
 * `gate`, `evaluator_runtime`, and `verdict` so operators can locate a
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
    if (item.evaluator_runtime && item.evaluator_runtime.toLowerCase().includes(needle)) return true
    if (item.verdict && item.verdict.toLowerCase().includes(needle)) return true
    return false
  })
}

/**
 * Pure filter for pre-compact events.
 *
 * Case-insensitive substring match on `keeper_name`, `trigger`, and any entry
 * of `strategies`. Empty/whitespace query returns the input
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
    if (item.strategies.some(s => s.toLowerCase().includes(needle))) return true
    return false
  })
}

/**
 * Pure filter for handoff events.
 *
 * Case-insensitive substring match on `keeper_name`, `trace_id`,
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
    if (item.trace_id && item.trace_id.toLowerCase().includes(needle)) return true
    if (item.prev_trace_id && item.prev_trace_id.toLowerCase().includes(needle)) return true
    if (item.new_trace_id && item.new_trace_id.toLowerCase().includes(needle)) return true
    return false
  })
}

// ── Helper functions ──

// RailStatus consumers below intentionally retain `case 'idle': default:`
// pattern. Reason: data.overview.evaluator_status etc. arrive via
// `get<HarnessHealthData>('/api/v1/dashboard/harness-health')` — a type
// assertion, not a typed parse — so wire drift (older OCaml backend
// emitting a novel status) reaches these helpers with a value the type
// system promised wouldn't occur. The defensive default is load-bearing
// for prod render safety. Fixing properly requires a boundary parser
// (`membershipParse<RailStatus>` at load site) so a future RFC can flip
// these to `assertExhaustive`. Existing tests at lines 92, 118, 296 lock
// this contract via `'unknown' as any`.
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
      return 'border-[var(--ok-30)] bg-[var(--ok-12)] text-[var(--color-status-ok)]'
    case 'warning':
      return 'border-[var(--warn-30)] bg-[var(--warn-12)] text-[var(--color-status-warn)]'
    case 'stale':
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)]'
    case 'idle':
    default:
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-disabled)]'
  }
}

export function statusCardClass(status: RailStatus): string {
  switch (status) {
    case 'healthy':
      return 'border-[var(--ok-30)] bg-[var(--ok-12)]'
    case 'warning':
      return 'border-[var(--warn-30)] bg-[var(--warn-12)]'
    case 'stale':
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]'
    case 'idle':
    default:
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]'
  }
}

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
  return verdictToneClass(verdict)
}

export function verdictSummary(verdict: string): string {
  return verdictWithoutRejectPrefix(verdict)
}

export function heroTitle(data: HarnessHealthData): string {
  const statuses = [
    data.overview.evaluator_status,
    data.overview.pre_compact_status,
    data.overview.handoff_status,
  ]
  const msg = railStatusMessage(statuses)
  if (msg) return msg
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
    const bytes = data.overview.latest_pre_compact_checkpoint_bytes
    if (bytes == null) return '최근 압축 없음'
    return `체크포인트 ${bytes.toLocaleString()} B`
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
      return freshnessLabel(data.overview.handoff_last_event_at, '기록 없음')
  }
  return assertExhaustive(rail, 'HarnessRail')
}

// ── Small components ──

export function StatusPill({ status }: { status: RailStatus }) {
  return html`
    <${StatusChip} tone=${statusChipClass(status)} class="font-semibold">${railStatusLabel(status)}<//>
  `
}

export function EmptySignal({ text }: { text: string }) {
  return html`
    <div class="v2-lab-card rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-sm text-[var(--color-fg-disabled)]">
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
        <div class="v2-lab-row flex items-center gap-2">
          <span class="w-20 text-right font-mono text-xs text-[var(--color-fg-muted)]">${gate}</span>
          <div class="h-4 flex-1 overflow-hidden rounded-[var(--r-1)] bg-[var(--color-bg-hover)]">
            <div
              class="h-full rounded-[var(--r-1)] opacity-80 transition-[width]"
              style=${{ width: `${(count / max) * 100}%`, background: 'var(--color-accent-fg)' }}
            />
          </div>
          <span class="w-8 text-right text-xs text-[var(--color-fg-primary)]">${count}</span>
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
    <div class=${`v2-lab-card rounded-[var(--r-1)] border p-3 ${statusCardClass(status)}`}>
      <div class="flex items-start justify-between gap-3">
        <${ItemTitle}>${label}</${ItemTitle}>
        <${StatusPill} status=${status} />
      </div>
      <div class="mt-3 text-lg font-semibold text-[var(--color-fg-primary)]">${detail}</div>
      <div class="mt-1 text-xs text-[var(--color-fg-disabled)]">최근 신호 ${freshness}</div>
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
              <${ItemTitle} class="mt-1">하네스가 답하는 것</${ItemTitle}>
            </div>
          </div>
          <div class="text-sm leading-loose text-[var(--color-fg-primary)]">
            evaluator와 장기 연속성 rail의 상태를 확인합니다.
          </div>
        </div>
      <//>

      <${SurfaceCard} variant="compact">
        <div class="flex flex-col gap-2">
          <${SectionCap}>안전 감시<//>
          <${ItemTitle}>하네스가 답하는 것</${ItemTitle}>
          <div class="text-sm leading-loose text-[var(--color-fg-primary)]">
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
          <${ItemTitle}>${title}</${ItemTitle}>
          <${StatusPill} status=${status} />
        </div>
        <div class="mt-1 text-sm leading-loose text-[var(--color-fg-muted)]">${description}</div>
      </div>
      <div class="text-xs text-[var(--color-fg-disabled)]">최근 신호 ${freshnessLabel(lastEventAt)}</div>
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
        <${TextInput}
          type="search"
          class="min-w-40 max-w-65 flex-1 !px-2 !py-1 !text-2xs"
          value=${query.value}
          placeholder="task / agent / gate / runtime 필터"
          ariaLabel="판정 필터"
          onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
        />
      </div>
      ${isFiltering && visibleItems.length === 0
        ? html`<div class="py-4 text-center text-2xs text-[var(--color-fg-disabled)]">필터 결과 없음 (${items.length} items)</div>`
        : visibleItems.map(item => html`
          <${SurfaceCard} variant="compact">
            <div class="flex items-start justify-between gap-3">
              <div>
                <${ItemTitle}>${item.task_title || item.task_id}</${ItemTitle}>
                <div class="mt-1 text-xs text-[var(--color-fg-muted)]">
                  ${item.agent_name || '(unknown agent)'} · ${item.gate || '(unknown gate)'} · ${item.evaluator_runtime || '(unknown runtime)'} · ${formatTimestampKo(item.timestamp)}
                </div>
              </div>
              <${StatusDot} size="md" class=${verdictTone(item.verdict)} />
            </div>
            <div class="mt-2 text-sm text-[var(--color-fg-primary)]">${verdictSummary(item.verdict)}</div>
            ${item.fallback_reason ? html`
              <div class="mt-2 break-all text-xs text-[var(--color-status-warn)]">${item.fallback_reason}</div>
            ` : null}
          <//>
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
        <${TextInput}
          type="search"
          class="min-w-40 max-w-65 flex-1 !px-2 !py-1 !text-2xs"
          value=${query.value}
          placeholder="keeper / trigger / strategy 필터"
          ariaLabel="압축 이벤트 필터"
          onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
        />
      </div>
      ${isFiltering && visibleItems.length === 0
        ? html`<div class="py-4 text-center text-2xs text-[var(--color-fg-disabled)]">필터 결과 없음 (${section.recent_events.length} items)</div>`
        : visibleItems.map(item => html`
          <${SurfaceCard} variant="compact">
            <div class="flex items-start justify-between gap-3">
              <${ItemTitle}>${item.keeper_name}</${ItemTitle}>
              <div class="text-xs text-[var(--color-fg-muted)]">${formatTimestampKo(item.timestamp)}</div>
            </div>
            <div class="mt-2 grid grid-cols-2 gap-2 text-xs text-[var(--color-fg-primary)]">
              <span>체크포인트 ${item.checkpoint_bytes.toLocaleString()} B</span>
              <span>메시지 ${item.message_count}건</span>
            </div>
            <div class="mt-2 text-xs text-[var(--color-fg-muted)]">${item.trigger}</div>
            ${item.strategies.length > 0 ? html`
              <div class="mt-2 flex flex-wrap gap-1">
                ${item.strategies.map(strategy => html`
                  <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-2 py-0.5 text-3xs text-[var(--color-fg-muted)]">${strategy}</span>
                `)}
              </div>
            ` : null}
          <//>
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
        <${TextInput}
          type="search"
          class="min-w-40 max-w-65 flex-1 !px-2 !py-1 !text-2xs"
          value=${query.value}
          placeholder="keeper / trace_id 필터"
          ariaLabel="세대 교체 필터"
          onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
        />
      </div>
      ${isFiltering && visibleItems.length === 0
        ? html`<div class="py-4 text-center text-2xs text-[var(--color-fg-disabled)]">필터 결과 없음 (${section.recent_events.length} items)</div>`
        : visibleItems.map(item => html`
          <${SurfaceCard} variant="compact">
            <div class="flex items-start justify-between gap-3">
              <${ItemTitle}>${item.keeper_name}</${ItemTitle}>
              <div class="text-xs text-[var(--color-fg-muted)]">${formatTimestampKo(item.timestamp)}</div>
            </div>
            <div class="mt-2 grid grid-cols-2 gap-2 text-xs text-[var(--color-fg-primary)]">
              <span>${item.generation}세대</span>
              <span>다음 ${item.next_generation ?? '-'}세대</span>
              <span class="inline-flex items-center gap-1">
                <span class="font-mono" title=${item.trace_id}>${item.trace_id.slice(0, 8)}</span>
                <${CopyIdButton} value=${item.trace_id} label="trace_id" size=${10} />
              </span>
              <span>runtime</span>
            </div>
            ${item.prev_trace_id ? html`
              <div class="mt-2 text-xs text-[var(--color-fg-muted)]">이전 ${item.prev_trace_id.slice(0, 8)} → 새 ${item.new_trace_id?.slice(0, 8) ?? '-'}</div>
            ` : null}
          <//>
        `)}
    </div>
  `
}
