// Cascade Waterfall — per-turn cascade attempt visualization.
//
// Shows the cascade strategy trace as a waterfall chart: each row
// is a strategy-selection event; bars show attempt counts and outcomes.
// Data comes from /api/v1/cascade/strategy_trace (already polled by
// cascade-inspector.ts; here we re-use the same API for a focused view).
//
// Companion to cascade-inspector.ts (detailed table) and
// cascade-config-panel.ts (config + health); this view emphasises
// temporal ordering of cascade *decisions* per cycle so operators can
// see whether fallbacks are accumulating.

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import {
  fetchCascadeStrategyTrace,
  type CascadeStrategyTraceEvent,
} from '../api/dashboard-cascade'
import { LoadingState, ErrorState } from './common/feedback-state'
import { TimeAgo } from './common/time-ago'

// ── Module-level signals ──────────────────────────────────────────────────

const waterfallLoading = signal(false)
const waterfallError = signal<string | null>(null)
const waterfallEvents = signal<CascadeStrategyTraceEvent[]>([])
const waterfallUpdatedAt = signal<string>('')
const waterfallFilter = signal<string>('all')

// ── Derived ───────────────────────────────────────────────────────────────

const waterfallCascadeNames = computed(() => {
  const names = new Set<string>()
  for (const e of waterfallEvents.value) names.add(e.cascade_name)
  return ['all', ...[...names].sort()]
})

const filteredWaterfallEvents = computed(() => {
  const sel = waterfallFilter.value
  if (sel === 'all') return waterfallEvents.value
  return waterfallEvents.value.filter(e => e.cascade_name === sel)
})

// ── Helpers ───────────────────────────────────────────────────────────────

/** Return a semantic tone for a cascade strategy trace outcome. */
export function cascadeKindTone(kind: string): {
  color: string
  bg: string
  border: string
  label: string
} {
  switch (kind) {
    case 'ordered':
      return {
        color: 'var(--color-status-ok)',
        bg: 'var(--ok-10)',
        border: 'var(--ok-20)',
        label: '순차',
      }
    case 'filtered_empty':
      return {
        color: 'var(--color-status-warn)',
        bg: 'var(--warn-10)',
        border: 'var(--warn-20)',
        label: '필터 소진',
      }
    case 'exhausted':
      return {
        color: 'var(--bad-light)',
        bg: 'var(--bad-10)',
        border: 'var(--bad-20)',
        label: '모두 소진',
      }
    default:
      return {
        color: 'var(--color-fg-muted)',
        bg: 'var(--color-bg-elevated)',
        border: 'var(--color-border-default)',
        label: kind,
      }
  }
}

/** Normalise backoff_ms into a human-readable string. */
export function formatBackoff(ms: number): string {
  if (ms <= 0) return '-'
  if (ms < 1000) return `${ms}ms`
  return `${(ms / 1000).toFixed(1)}s`
}

/** Cap bar width at 100% based on the max candidates_in across visible events. */
export function barWidthPct(value: number, max: number): number {
  if (max <= 0 || value <= 0) return 0
  return Math.min(100, Math.round((value / max) * 100))
}

// ── Data loading ──────────────────────────────────────────────────────────

async function refreshWaterfall() {
  waterfallLoading.value = true
  waterfallError.value = null
  try {
    const res = await fetchCascadeStrategyTrace({ limit: 100 })
    waterfallEvents.value = res.events
    waterfallUpdatedAt.value = res.updated_at
  } catch (err) {
    waterfallError.value = err instanceof Error ? err.message : String(err)
  } finally {
    waterfallLoading.value = false
  }
}

// ── Sub-components ────────────────────────────────────────────────────────

function WaterfallRow({
  ev,
  maxIn,
}: {
  ev: CascadeStrategyTraceEvent
  maxIn: number
}) {
  const tone = cascadeKindTone(ev.kind)
  const inPct = barWidthPct(ev.candidates_in, maxIn)
  const outPct = barWidthPct(ev.candidates_out, maxIn)
  const filtered = ev.candidates_in - ev.candidates_out

  return html`
    <div
      class="grid gap-2 py-2 px-3 rounded-[var(--r-1)] border bg-[var(--color-bg-surface)]"
      style="border-color: ${tone.border}"
      role="row"
      aria-label="캐스케이드 ${ev.cascade_name} 사이클 ${ev.cycle}"
    >
      <!-- Header row -->
      <div class="flex flex-wrap items-center gap-2 text-2xs">
        <span
          class="inline-flex items-center rounded-[var(--r-0)] px-2 py-px text-3xs font-semibold"
          style="color: ${tone.color}; background: ${tone.bg}; border: 1px solid ${tone.border}"
        >${tone.label}</span>
        <span class="font-mono font-semibold text-[var(--color-fg-secondary)]">${ev.cascade_name}</span>
        <span class="text-[var(--color-fg-muted)]">${ev.strategy}</span>
        <span class="text-[var(--color-fg-disabled)] ml-auto tabular-nums">
          <${TimeAgo} timestamp=${ev.ts * 1000} />
        </span>
      </div>

      <!-- Waterfall bars: candidates_in (gray) behind candidates_out (color) -->
      <div class="flex flex-col gap-1">
        <div class="relative h-3 rounded-[var(--r-0)] overflow-hidden bg-[var(--color-bg-hover)]">
          <!-- candidates_in base bar -->
          <div
            class="absolute inset-y-0 left-0 rounded-[var(--r-0)]"
            style="width: ${inPct}%; background: var(--color-border-default)"
          />
          <!-- candidates_out overlay bar -->
          <div
            class="absolute inset-y-0 left-0 rounded-[var(--r-0)] transition-[width]"
            style="width: ${outPct}%; background: ${tone.color}; opacity: 0.7"
          />
        </div>
        <div class="flex items-center gap-3 text-3xs text-[var(--color-fg-muted)] tabular-nums">
          <span>입력 ${ev.candidates_in}</span>
          <span>출력 ${ev.candidates_out}</span>
          ${filtered > 0
            ? html`<span class="text-[var(--color-status-warn)]">필터됨 ${filtered}</span>`
            : null}
          ${ev.backoff_ms > 0
            ? html`<span class="text-[var(--color-fg-disabled)]">백오프 ${formatBackoff(ev.backoff_ms)}</span>`
            : null}
          <span class="ml-auto">사이클 ${ev.cycle}</span>
        </div>
      </div>
    </div>
  `
}

// ── Public component ──────────────────────────────────────────────────────

export function CascadeWaterfallPanel() {
  useEffect(() => { void refreshWaterfall() }, [])

  const isLoading = waterfallLoading.value
  const error = waterfallError.value
  const events = filteredWaterfallEvents.value
  const names = waterfallCascadeNames.value
  const updatedAt = waterfallUpdatedAt.value

  if (isLoading && events.length === 0) {
    return html`<${LoadingState}>캐스케이드 전략 트레이스 불러오는 중...<//>`
  }

  if (error) {
    return html`<${ErrorState} message=${error} onRetry=${() => { void refreshWaterfall() }} />`
  }

  const maxIn = events.reduce((m, e) => Math.max(m, e.candidates_in), 1)

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex flex-wrap items-center gap-2 justify-between">
        <div>
          <div class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">
            캐스케이드 전략 워터폴
          </div>
          ${updatedAt
            ? html`<div class="text-3xs text-[var(--color-fg-disabled)] mt-0.5">
                갱신: <${TimeAgo} timestamp=${updatedAt} />
              </div>`
            : null}
        </div>
        <div class="flex items-center gap-2">
          ${names.length > 1
            ? html`
              <select
                aria-label="캐스케이드 필터"
                class="py-1 px-2 rounded-[var(--r-1)] text-3xs bg-[var(--color-bg-surface)] text-[var(--color-fg-secondary)] border border-[var(--color-border-default)] cursor-pointer"
                value=${waterfallFilter.value}
                onChange=${(e: Event) => { waterfallFilter.value = (e.target as HTMLSelectElement).value }}
              >
                ${names.map(n => html`<option value=${n}>${n === 'all' ? '전체' : n}</option>`)}
              </select>
            `
            : null}
          <button
            type="button"
            class="text-2xs text-[var(--color-fg-disabled)] hover:text-[var(--color-fg-primary)] transition-colors"
            onClick=${() => { void refreshWaterfall() }}
          >새로고침</button>
        </div>
      </div>

      ${events.length === 0
        ? html`<div class="text-xs text-[var(--color-fg-muted)] py-4 text-center">전략 트레이스 없음 — 캐스케이드가 아직 활동하지 않았습니다.</div>`
        : html`
          <div class="flex flex-col gap-2" role="table" aria-label="캐스케이드 전략 워터폴 이벤트">
            ${events.map((ev, i) => html`
              <${WaterfallRow} ev=${ev} maxIn=${maxIn} key=${i} />
            `)}
          </div>
        `}
    </div>
  `
}
