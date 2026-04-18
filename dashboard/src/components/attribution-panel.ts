// Attribution Panel — Layer 4 observation surface.
//
// 관찰 대시보드. 4-field per event: 누가(gate) / 어디서(origin) / 뭘(outcome) /
// 왜(reason). Graph instead of sankey — actual events don't carry correlation
// ids yet, so per-gate card + recent-event list is the honest view.

import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchAttributionRecent,
  fetchAttributionSummary,
  type Attribution,
  type AttributionEvent,
  type AttributionSummaryResponse,
  type GateSummary,
} from '../api/attribution'
import { SurfaceCard } from './common/card'
import { ErrorState, LoadingState } from './common/feedback-state'
import { EmptyState } from './common/empty-state'
import { highlightMatch } from '../lib/highlight-match'

const POLL_INTERVAL_MS = 5_000
const RECENT_LIMIT = 50

// Known gates. Gates not yet wired (accountability, coord_task, etc.) will
// show zero counts so the operator sees which sources are live.
const KNOWN_GATES = [
  'cdal_verdict',
  'verification',
  'keeper_fsm',
  'worker_dev_tools',
  'accountability',
  'autoresearch',
  'oas_completion',
  'agent_lifecycle',
] as const

function outcomeLabel(a: Attribution): string {
  switch (a.outcome.kind) {
    case 'passed': return '통과'
    case 'policy_failed': return '정책 실패'
    case 'transition_blocked': return '전이 차단'
    case 'partial_pass': return '부분 통과'
  }
}

function outcomeToneClass(kind: Attribution['outcome']['kind']): string {
  switch (kind) {
    case 'passed': return 'text-[var(--ok)]'
    case 'policy_failed': return 'text-[var(--bad-light)]'
    case 'transition_blocked': return 'text-[var(--bad-light)]'
    case 'partial_pass': return 'text-[var(--warn)]'
  }
}

function originBadgeClass(origin: Attribution['origin']): string {
  return origin === 'det'
    ? 'bg-[var(--accent-10)]0/20 text-[var(--accent)] border border-[var(--accent-20)]0/40'
    : 'bg-[var(--accent-10)]0/20 text-[var(--accent)] border border-[var(--accent-20)]0/40'
}

function formatTs(recordedAt: number): string {
  const d = new Date(recordedAt * 1000)
  return d.toLocaleTimeString('ko-KR', { hour12: false })
}

function reasonOf(a: Attribution): string {
  switch (a.outcome.kind) {
    case 'policy_failed': return a.outcome.reason
    case 'transition_blocked':
      return `${a.outcome.from_state} → ${a.outcome.to_state}: ${a.outcome.reason}`
    case 'partial_pass': return a.outcome.rationale
    case 'passed': return ''
  }
}

/**
 * Pure filter for attribution events.
 *
 * Case-insensitive substring match on `gate`, `origin`, and the outcome's
 * textual fields (reason / rationale / from_state / to_state) so operators
 * can locate an event by gate name, by det/nondet origin, or by a snippet
 * of the failure reason.
 *
 * Empty/whitespace query returns the input reference unchanged (no new
 * array allocation, preserves referential equality for memoisation).
 *
 * Input is never mutated.
 */
export function filterAttributionEvents(
  events: readonly AttributionEvent[],
  query: string,
): readonly AttributionEvent[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return events
  return events.filter(ev => {
    const a = ev.attribution
    if (a.gate.toLowerCase().includes(needle)) return true
    if (a.origin.toLowerCase().includes(needle)) return true
    const o = a.outcome
    switch (o.kind) {
      case 'passed':
        return false
      case 'policy_failed':
        return o.reason.toLowerCase().includes(needle)
      case 'transition_blocked':
        if (o.reason.toLowerCase().includes(needle)) return true
        if (o.from_state.toLowerCase().includes(needle)) return true
        if (o.to_state.toLowerCase().includes(needle)) return true
        return false
      case 'partial_pass':
        return o.rationale.toLowerCase().includes(needle)
    }
  })
}

function GateCard({
  gate, summary, onSelect,
}: {
  gate: string
  summary: GateSummary | null
  onSelect: () => void
}) {
  const isLive = summary !== null && summary.total > 0
  const toneClass = isLive ? '' : 'opacity-50'
  const passed = summary?.passed ?? 0
  const policyFailed = summary?.policy_failed ?? 0
  const blocked = summary?.transition_blocked ?? 0
  const partial = summary?.partial_pass ?? 0
  const total = summary?.total ?? 0

  return html`
    <button
      type="button"
      class="text-left w-full focus:outline-none focus:ring-2 focus:ring-[var(--accent-20)]0/50 rounded ${toneClass}"
      onClick=${onSelect}
    >
      <${SurfaceCard} variant="compact">
        <div class="flex flex-col gap-2">
          <div class="flex items-baseline justify-between">
            <span class="text-[12px] font-semibold tracking-tight">${gate}</span>
            <span class="text-[10px] text-[var(--text-muted)]">${total}건</span>
          </div>
          <div class="grid grid-cols-2 gap-1 text-[11px]">
            <span class="text-[var(--ok)]">✓ ${passed}</span>
            <span class="text-[var(--warn)]">◐ ${partial}</span>
            <span class="text-[var(--bad-light)]">✗ ${policyFailed}</span>
            <span class="text-[var(--bad-light)]">⊘ ${blocked}</span>
          </div>
        </div>
      </${SurfaceCard}>
    </button>
  `
}

function EventRow({
  event, onSelect, active, query,
}: {
  event: AttributionEvent
  onSelect: () => void
  active: boolean
  query: string
}) {
  const a = event.attribution
  const rowBg = active
    ? 'bg-white/5'
    : 'hover:bg-white/5'
  const reasonText = reasonOf(a)
  return html`
    <button
      type="button"
      class="w-full text-left px-3 py-2 border-b border-[var(--card-border)] flex items-center gap-3 text-[12px] ${rowBg}"
      onClick=${onSelect}
    >
      <span class="text-[11px] font-mono text-[var(--text-muted)] w-20 shrink-0">
        ${formatTs(event.recorded_at)}
      </span>
      <span class="text-[10px] px-1.5 py-0.5 rounded ${originBadgeClass(a.origin)} shrink-0">
        ${highlightMatch(a.origin, query)}
      </span>
      <span class="font-mono text-[11px] w-36 shrink-0">${highlightMatch(a.gate, query)}</span>
      <span class="${outcomeToneClass(a.outcome.kind)} shrink-0 w-20">
        ${outcomeLabel(a)}
      </span>
      <span class="text-[var(--text-muted)] truncate grow min-w-0">
        ${reasonText ? highlightMatch(reasonText, query) : '—'}
      </span>
    </button>
  `
}

function EvidenceDetail({ event }: { event: AttributionEvent | null }) {
  if (!event) {
    return html`
      <${SurfaceCard} variant="light">
        <${EmptyState} message="이벤트를 선택하면 evidence가 여기 표시됩니다." />
      </${SurfaceCard}>
    `
  }
  const a = event.attribution
  const evidenceJson = JSON.stringify(a.evidence, null, 2)
  return html`
    <${SurfaceCard} variant="compact">
      <div class="flex flex-col gap-3">
        <div class="flex items-baseline gap-3 flex-wrap">
          <span class="text-[11px] text-[var(--text-muted)]">${formatTs(event.recorded_at)}</span>
          <span class="font-mono text-[13px] font-semibold">${a.gate}</span>
          <span class="text-[10px] px-1.5 py-0.5 rounded ${originBadgeClass(a.origin)}">
            ${a.origin}
          </span>
          <span class="${outcomeToneClass(a.outcome.kind)} text-[12px]">
            ${outcomeLabel(a)}
          </span>
        </div>
        ${reasonOf(a)
          ? html`<div class="text-[12px] text-[var(--text-muted)]">${reasonOf(a)}</div>`
          : null}
        <pre class="text-[11px] font-mono bg-[var(--white-5)]/30 rounded p-3 overflow-x-auto max-h-64 whitespace-pre-wrap">${evidenceJson}</pre>
      </div>
    </${SurfaceCard}>
  `
}

export function AttributionPanel() {
  const summary = useSignal<AttributionSummaryResponse | null>(null)
  const recent = useSignal<AttributionEvent[]>([])
  const loading = useSignal(true)
  const error = useSignal<string | null>(null)
  const selectedEventIdx = useSignal<number | null>(null)
  const filterGate = useSignal<string | null>(null)
  const query = useSignal('')

  useEffect(() => {
    let cancelled = false
    const ctl = new AbortController()

    const load = async () => {
      try {
        const [s, r] = await Promise.all([
          fetchAttributionSummary({ signal: ctl.signal }),
          fetchAttributionRecent(
            {
              limit: RECENT_LIMIT,
              ...(filterGate.value ? { gate: filterGate.value } : {}),
            },
            { signal: ctl.signal },
          ),
        ])
        if (cancelled) return
        summary.value = s
        recent.value = r.events
        error.value = null
      } catch (e) {
        if (cancelled || (e as Error).name === 'AbortError') return
        error.value = (e as Error).message || 'attribution fetch failed'
      } finally {
        if (!cancelled) loading.value = false
      }
    }

    load()
    const iv = window.setInterval(load, POLL_INTERVAL_MS)
    return () => {
      cancelled = true
      ctl.abort()
      window.clearInterval(iv)
    }
  }, [filterGate.value])

  if (loading.value && !summary.value) {
    return html`<${LoadingState} message="attribution 로딩 중…" />`
  }
  if (error.value && !summary.value) {
    return html`<${ErrorState} message=${error.value} />`
  }

  const byGate = new Map<string, GateSummary>()
  for (const g of summary.value?.gates ?? []) byGate.set(g.gate, g)

  // Gate filter runs server-side (see fetchAttributionRecent above), so
  // `recent.value` is already gate-filtered. Text filter composes on top.
  const gateFiltered = recent.value
  const visibleEvents = useMemo(
    () => filterAttributionEvents(gateFiltered, query.value),
    [gateFiltered, query.value],
  )
  const isFiltering = query.value.trim() !== ''

  const selected = selectedEventIdx.value !== null
    ? visibleEvents[selectedEventIdx.value] ?? null
    : null

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex flex-col gap-1">
        <div class="text-[11px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
          Attribution — gate chain 관찰
        </div>
        <p class="m-0 text-[12px] leading-[1.55] text-[var(--text-muted)]">
          각 gate의 결과 카운트 + 최근 ${RECENT_LIMIT}건 이벤트. 5초마다 자동 갱신.
        </p>
      </div>

      <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
        ${KNOWN_GATES.map(gate => html`
          <${GateCard}
            gate=${gate}
            summary=${byGate.get(gate) ?? null}
            onSelect=${() => {
              filterGate.value = filterGate.value === gate ? null : gate
              selectedEventIdx.value = null
            }}
          />
        `)}
      </div>

      <div class="flex items-center justify-between gap-2 flex-wrap">
        ${filterGate.value
          ? html`
            <div class="text-[11px] text-[var(--text-muted)]">
              필터: <span class="font-mono text-[var(--text-primary)]">${filterGate.value}</span>
              <button
                class="ml-2 underline"
                onClick=${() => { filterGate.value = null }}
              >
                해제
              </button>
            </div>`
          : html`<div></div>`}
        <input
          type="search"
          value=${query.value}
          placeholder="gate / origin / reason 필터"
          aria-label="Attribution 이벤트 필터"
          onInput=${(e: Event) => {
            query.value = (e.target as HTMLInputElement).value
            selectedEventIdx.value = null
          }}
          class="min-w-[160px] max-w-[240px] flex-1 rounded border border-[var(--card-border)] bg-[var(--white-5)]/20 px-2 py-1 text-[11px] text-[var(--text-primary)] placeholder:text-[var(--text-muted)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-20)]0/50"
        />
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <${SurfaceCard} variant="light">
          <div class="flex flex-col">
            <div class="px-3 py-2 border-b border-[var(--card-border)] text-[11px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
              최근 이벤트 (${isFiltering
                ? `${visibleEvents.length}/${gateFiltered.length}`
                : gateFiltered.length})
            </div>
            ${gateFiltered.length === 0
              ? html`<${EmptyState} message=${filterGate.value
                  ? `이 gate에 해당하는 이벤트가 없습니다 (${filterGate.value}).`
                  : '이벤트가 없습니다.'} />`
              : visibleEvents.length === 0
                ? html`<${EmptyState} message=${`필터 결과 없음 (${gateFiltered.length}건 중)`} />`
                : visibleEvents.map((ev, idx) => html`
                  <${EventRow}
                    event=${ev}
                    active=${selectedEventIdx.value === idx}
                    query=${query.value}
                    onSelect=${() => { selectedEventIdx.value = idx }}
                  />
                `)}
          </div>
        </${SurfaceCard}>

        <${EvidenceDetail} event=${selected} />
      </div>
    </div>
  `
}
