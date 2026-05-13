// Cascade Inspector — strategy trace, profile health, and candidate deep-dive.
// Phase F6: O1 Cascade Inspector surface (monitoring section).

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import {
  fetchCascadeStrategyTrace,
  fetchCascadeHealth,
  type CascadeStrategyTraceEvent,
  type CascadeHealthProvider,
} from '../api/dashboard-cascade'
import { replaceRoute, route } from '../router'
import { LoadingState, ErrorState, EmptyState } from './common/feedback-state'
import { FilterChips } from './common/filter-chips'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'

export type CascadeInspectorFocus = 'deep-dive' | 'compare'
type CascadeInspectorChip = 'trace' | CascadeInspectorFocus

const CASCADE_INSPECTOR_FOCUSES: CascadeInspectorFocus[] = ['deep-dive', 'compare']

export function isCascadeInspectorFocus(v: string | undefined): v is CascadeInspectorFocus {
  return !!v && (CASCADE_INSPECTOR_FOCUSES as string[]).includes(v)
}

export function cascadeInspectorRouteParams(focus: CascadeInspectorChip): Record<string, string> {
  return focus === 'trace'
    ? { section: 'runtime', view: 'inspector' }
    : { section: 'runtime', view: 'inspector', focus }
}

export function cascadeEventKey(event: CascadeStrategyTraceEvent): string {
  return JSON.stringify([event.ts, event.cascade_name, event.cycle, event.kind])
}

function NumCell({ children }: { children: unknown }) {
  return html`<td class="px-3 py-2 text-right tabular-nums text-text-muted">${children}</td>`
}

function ThRight({ children }: { children: unknown }) {
  return html`<th class="px-3 py-2 font-semibold text-right">${children}</th>`
}

function ThBase({ children }: { children: unknown }) {
  return html`<th class="px-3 py-2 font-semibold">${children}</th>`
}

// -- Local state -------------------------------------------------

const traceLoading = signal<boolean>(false)
const traceError = signal<string | null>(null)
const traceEvents = signal<CascadeStrategyTraceEvent[]>([])
const traceUpdatedAt = signal<string>('')
const healthLoading = signal<boolean>(false)
const healthError = signal<string | null>(null)
const healthProviders = signal<CascadeHealthProvider[]>([])
const selectedCascade = signal<string>('all')
const activeCascadeFocus = computed<CascadeInspectorFocus | null>(() => {
  const focus = route.value.params.focus
  return isCascadeInspectorFocus(focus) ? focus : null
})

// -- Derived -----------------------------------------------------

const cascadeNames = computed(() => {
  const names = new Set<string>()
  for (const e of traceEvents.value) names.add(e.cascade_name)
  return [...names].sort()
})

const filteredEvents = computed(() => {
  const sel = selectedCascade.value
  if (sel === 'all') return traceEvents.value
  return traceEvents.value.filter(e => e.cascade_name === sel)
})

const latestEvents = computed(() =>
  filteredEvents.value.slice().sort((a, b) => b.ts - a.ts),
)

// -- Data fetching -----------------------------------------------

async function refreshTrace() {
  traceLoading.value = true
  traceError.value = null
  try {
    const res = await fetchCascadeStrategyTrace({ limit: 200 })
    traceEvents.value = res.events
    traceUpdatedAt.value = res.updated_at
  } catch (err) {
    traceError.value = err instanceof Error ? err.message : String(err)
  } finally {
    traceLoading.value = false
  }
}

async function refreshHealth() {
  healthLoading.value = true
  healthError.value = null
  try {
    const res = await fetchCascadeHealth()
    healthProviders.value = res.providers
  } catch (err) {
    healthError.value = err instanceof Error ? err.message : String(err)
  } finally {
    healthLoading.value = false
  }
}

export function refreshCascadeInspector(): void {
  void refreshTrace()
  void refreshHealth()
}

// -- Sub-components ----------------------------------------------

function TraceKindBadge({ kind }: { kind: string }) {
  const tone: 'ok' | 'warn' | 'bad' =
    kind === 'ordered' ? 'ok'
    : kind === 'filtered_empty' ? 'warn'
    : 'bad'
  const label =
    kind === 'ordered' ? '정상'
    : kind === 'filtered_empty' ? '필터링'
    : '고갈'
  return html`<${StatusBadge} tone=${tone}>${label}<//>`
}

function candidateBarPct(value: number, max: number): number {
  if (max <= 0 || value <= 0) return 0
  return Math.min(100, Math.round((value / max) * 100))
}

function updateCascadeFocusParam(focus: CascadeInspectorChip): void {
  replaceRoute('monitoring', cascadeInspectorRouteParams(focus))
}

function CascadeFocusRail({
  focus,
  traceCount,
}: {
  focus: CascadeInspectorFocus | null
  traceCount: number
}) {
  const active: CascadeInspectorChip = focus ?? 'trace'
  return html`
    <div class="flex flex-col gap-2" aria-label="Cascade inspector focus" data-testid="cascade-focus-rail">
      <${FilterChips}
        chips=${[
          { key: 'trace', label: 'Trace', count: traceCount, title: 'strategy trace와 runtime health' },
          { key: 'deep-dive', label: 'Deep dive', count: traceCount, title: 'latest cascade decision detail' },
          { key: 'compare', label: 'Compare', count: traceCount, title: 'ordered vs filtered/exhausted decisions' },
        ]}
        value=${active}
        onChange=${updateCascadeFocusParam}
        size="sm"
        tone="accent"
      />
    </div>
  `
}

function StrategyTraceTable({ events }: { events: CascadeStrategyTraceEvent[] }) {
  if (events.length === 0) {
    return html`<${EmptyState} message="전략 추적 이벤트가 없습니다" compact />`
  }

  return html`
    <div class="overflow-x-auto rounded-[var(--r-1)] border border-card-border/60">
      <table class="w-full text-left text-xs">
        <thead class="bg-[var(--color-bg-surface)] text-text-muted">
          <tr>
            <${ThBase}>시간</${ThBase}>
            <${ThBase}>Cascade</${ThBase}>
            <${ThBase}>전략</${ThBase}>
            <${ThRight}>Cycle</${ThRight}>
            <${ThRight}>후보</${ThRight}>
            <${ThRight}>백오프(ms)</${ThRight}>
            <${ThBase}>결과</${ThBase}>
          </tr>
        </thead>
        <tbody class="divide-y divide-card-border/40">
          ${events.map(e => html`
            <tr key=${cascadeEventKey(e)} class="hover:bg-[var(--color-bg-surface)] transition-colors">
              <td class="px-3 py-2 text-text-body whitespace-nowrap">
                <${TimeAgo} timestamp=${e.ts} />
              </td>
              <td class="px-3 py-2 font-medium text-text-strong">${e.cascade_name}</td>
              <td class="px-3 py-2 text-text-body">${e.strategy}</td>
              <${NumCell}>${e.cycle}<//>
              <${NumCell}>${e.candidates_in}→${e.candidates_out}<//>
              <${NumCell}>${e.backoff_ms}<//>
              <td class="px-3 py-2">
                <${TraceKindBadge} kind=${e.kind} />
              </td>
            </tr>
          `)}
        </tbody>
      </table>
    </div>
  `
}

function CascadeEventCard({
  event,
  maxCandidates,
}: {
  event: CascadeStrategyTraceEvent
  maxCandidates: number
}) {
  const inPct = candidateBarPct(event.candidates_in, maxCandidates)
  const outPct = candidateBarPct(event.candidates_out, maxCandidates)
  const rejected = Math.max(0, event.candidates_in - event.candidates_out)

  return html`
    <article
      class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-surface)] p-3"
      aria-label=${`${event.cascade_name} cycle ${event.cycle} ${event.kind}`}
    >
      <div class="flex flex-wrap items-center gap-2 text-2xs">
        <${TraceKindBadge} kind=${event.kind} />
        <span class="font-mono font-semibold text-text-strong">${event.cascade_name}</span>
        <span class="text-text-muted">${event.strategy}</span>
        <span class="ml-auto text-text-muted tabular-nums"><${TimeAgo} timestamp=${event.ts} /></span>
      </div>
      <div class="mt-3 flex flex-col gap-1">
        <div class="relative h-3 overflow-hidden rounded-[var(--r-0)] bg-[var(--color-bg-hover)]">
          <div
            class="absolute inset-y-0 left-0 rounded-[var(--r-0)] bg-[var(--color-border-default)]"
            style=${`width: ${inPct}%`}
          />
          <div
            class="absolute inset-y-0 left-0 rounded-[var(--r-0)] bg-[var(--color-accent-fg)] opacity-70"
            style=${`width: ${outPct}%`}
          />
        </div>
        <div class="flex flex-wrap items-center gap-3 text-3xs tabular-nums text-text-muted">
          <span>in ${event.candidates_in}</span>
          <span>out ${event.candidates_out}</span>
          ${rejected > 0 ? html`<span class="text-warn">filtered ${rejected}</span>` : null}
          ${event.backoff_ms > 0 ? html`<span>backoff ${event.backoff_ms}ms</span>` : null}
          <span class="ml-auto">cycle ${event.cycle}</span>
        </div>
      </div>
    </article>
  `
}

function CascadeDeepDivePanel({ events }: { events: CascadeStrategyTraceEvent[] }) {
  if (events.length === 0) {
    return html`<${EmptyState} message="deep-dive에 표시할 cascade 전략 이벤트가 없습니다" compact />`
  }

  const visible = events.slice(0, 6)
  const maxCandidates = Math.max(1, ...visible.map(e => e.candidates_in))

  return html`
    <section class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-4" aria-label="Cascade deep dive" data-testid="cascade-deep-dive">
      <div class="mb-3 flex flex-wrap items-baseline justify-between gap-2">
        <div>
          <div class="text-2xs font-semibold uppercase tracking-5 text-text-muted">Deep dive</div>
          <h3 class="mt-1 text-md font-semibold text-text-strong">최근 cascade 결정</h3>
        </div>
        <span class="text-2xs text-text-muted">${visible.length}/${events.length} events</span>
      </div>
      <div class="grid gap-2 md:grid-cols-2">
        ${visible.map(event => html`
          <${CascadeEventCard}
            key=${cascadeEventKey(event)}
            event=${event}
            maxCandidates=${maxCandidates}
          />
        `)}
      </div>
    </section>
  `
}

function compareStats(events: CascadeStrategyTraceEvent[]) {
  const candidatesIn = events.reduce((sum, e) => sum + e.candidates_in, 0)
  const candidatesOut = events.reduce((sum, e) => sum + e.candidates_out, 0)
  const backoffMs = events.reduce((sum, e) => sum + e.backoff_ms, 0)
  return { candidatesIn, candidatesOut, filtered: Math.max(0, candidatesIn - candidatesOut), backoffMs }
}

function CascadeCompareColumn({
  title,
  events,
}: {
  title: string
  events: CascadeStrategyTraceEvent[]
}) {
  const stats = compareStats(events)
  const visible = events.slice(0, 5)

  return html`
    <section class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-surface)] p-3">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h4 class="text-sm font-semibold text-text-strong">${title}</h4>
        <span class="text-2xs text-text-muted">${events.length} events</span>
      </div>
      <dl class="mt-3 grid grid-cols-2 gap-2 text-2xs sm:grid-cols-4">
        <div>
          <dt class="text-text-muted">input</dt>
          <dd class="font-mono text-text-strong">${stats.candidatesIn}</dd>
        </div>
        <div>
          <dt class="text-text-muted">output</dt>
          <dd class="font-mono text-text-strong">${stats.candidatesOut}</dd>
        </div>
        <div>
          <dt class="text-text-muted">filtered</dt>
          <dd class="font-mono text-text-strong">${stats.filtered}</dd>
        </div>
        <div>
          <dt class="text-text-muted">backoff</dt>
          <dd class="font-mono text-text-strong">${stats.backoffMs}ms</dd>
        </div>
      </dl>
      <div class="mt-3 flex flex-col gap-2">
        ${visible.length === 0
          ? html`<div class="rounded-[var(--r-1)] border border-dashed border-card-border/60 p-3 text-2xs text-text-muted">해당 이벤트 없음</div>`
          : visible.map(event => html`
            <div class="flex flex-wrap items-center gap-2 rounded-[var(--r-1)] border border-card-border/40 px-2 py-1 text-2xs">
              <${TraceKindBadge} kind=${event.kind} />
              <span class="font-mono text-text-strong">${event.cascade_name}</span>
              <span class="text-text-muted">${event.strategy}</span>
              <span class="ml-auto tabular-nums text-text-muted">cycle ${event.cycle}</span>
            </div>
          `)}
      </div>
    </section>
  `
}

function CascadeComparePanel({ events }: { events: CascadeStrategyTraceEvent[] }) {
  const ordered = events.filter(e => e.kind === 'ordered')
  const attention = events.filter(e => e.kind !== 'ordered')

  return html`
    <section class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-4" aria-label="Cascade compare" data-testid="cascade-compare">
      <div class="mb-3">
        <div class="text-2xs font-semibold uppercase tracking-5 text-text-muted">Compare</div>
        <h3 class="mt-1 text-md font-semibold text-text-strong">정상 결정 vs 필터/고갈 결정</h3>
      </div>
      <div class="grid gap-3 lg:grid-cols-2">
        <${CascadeCompareColumn} title="Ordered path" events=${ordered} />
        <${CascadeCompareColumn} title="Filtered / exhausted" events=${attention} />
      </div>
    </section>
  `
}

function ProviderHealthTable({ providers }: { providers: CascadeHealthProvider[] }) {
  if (providers.length === 0) {
    return html`<${EmptyState} message="런타임 건강 데이터가 없습니다" compact />`
  }

  return html`
    <div class="overflow-x-auto rounded-[var(--r-1)] border border-card-border/60">
      <table class="w-full text-left text-xs">
        <thead class="bg-[var(--color-bg-surface)] text-text-muted">
          <tr>
            <${ThBase}>런타임</${ThBase}>
            <${ThRight}>성공률</${ThRight}>
            <${ThRight}>연속 실패</${ThRight}>
            <${ThBase}>쿨다운</${ThBase}>
            <${ThRight}>이벤트</${ThRight}>
            <${ThRight}>평균 지연(ms)</${ThRight}>
          </tr>
        </thead>
        <tbody class="divide-y divide-card-border/40">
          ${providers.map((p, index) => html`
            <tr key=${`runtime-${index}`} class="hover:bg-[var(--color-bg-surface)] transition-colors">
              <td class="px-3 py-2 font-medium text-text-strong">runtime-${index + 1}</td>
              <td class="px-3 py-2 text-right tabular-nums ${p.success_rate >= 0.9 ? 'text-ok' : p.success_rate >= 0.7 ? 'text-warn' : 'text-bad'}">
                ${Math.round(p.success_rate * 100)}%
              </td>
              <td class="px-3 py-2 text-right tabular-nums ${p.consecutive_failures > 2 ? 'text-bad' : 'text-text-muted'}">
                ${p.consecutive_failures}
              </td>
              <td class="px-3 py-2">
                ${p.in_cooldown
                  ? html`<${StatusBadge} tone="warn">쿨다운 진행 중<//>`
                  : html`<span class="text-text-muted">-</span>`}
              </td>
              <${NumCell}>${p.events_in_window}<//>
              <${NumCell}>
                ${p.avg_latency_ms != null ? Math.round(p.avg_latency_ms) : '-'}
              <//>
            </tr>
          `)}
        </tbody>
      </table>
    </div>
  `
}

// -- Main component ----------------------------------------------

export function CascadeInspector() {
  useEffect(() => {
    refreshCascadeInspector()
  }, [])

  const names = cascadeNames.value
  const focus = activeCascadeFocus.value
  const events = latestEvents.value
  const filteredTraceCount = filteredEvents.value.length
  const chips = [
    { key: 'all', label: '전체' },
    ...names.map(n => ({ key: n, label: n })),
  ]

  return html`
    <div class="flex flex-col gap-8">
      <section class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-5" aria-label="Cascade 검사기">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <div class="text-2xs font-semibold uppercase tracking-[var(--track-label)] text-text-muted">Cascade 검사기</div>
            <h3 class="mt-2 text-[22px] font-semibold tracking-[-0.02em] text-text-strong">
              전략 추적 · 런타임 건강도
            </h3>
          </div>
          <${CascadeFocusRail}
            focus=${focus}
            traceCount=${filteredTraceCount}
          />
        </div>
      </section>

      ${traceLoading.value
        ? html`<${LoadingState}>이벤트 불러오는 중...<//>`
      : traceError.value
        ? html`<${ErrorState} message=${traceError.value} onRetry=${refreshTrace} />`
      : focus === 'deep-dive'
        ? html`<${CascadeDeepDivePanel} events=${events} />`
      : focus === 'compare'
        ? html`<${CascadeComparePanel} events=${events} />`
      : html`<section class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-4" aria-label="전략 추적">
        <div class="flex flex-wrap items-center justify-between gap-3 mb-3">
          <div>
            <div class="text-2xs font-semibold uppercase tracking-5 text-text-muted">전략 추적</div>
            <h3 class="mt-1 text-md font-semibold text-text-strong">최근 이벤트</h3>
          </div>
          ${names.length > 0 ? html`
            <${FilterChips}
              chips=${chips}
              value=${selectedCascade.value}
              onChange=${(v: string) => { selectedCascade.value = v }}
            />
          ` : null}
        </div>
        <${StrategyTraceTable} events=${filteredEvents.value} />
      </section>`}

      <section class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-4" aria-label="런타임 건강도">
        <div class="mb-3">
          <div class="text-2xs font-semibold uppercase tracking-5 text-text-muted">런타임</div>
          <h3 class="mt-1 text-md font-semibold text-text-strong">건강도 스냅숏</h3>
        </div>
        ${healthLoading.value
          ? html`<${LoadingState}>건강도 불러오는 중...<//>`
          : healthError.value
            ? html`<${ErrorState} message=${healthError.value} onRetry=${refreshHealth} />`
            : html`<${ProviderHealthTable} providers=${healthProviders.value} />`
        }
      </section>
    </div>
  `
}
