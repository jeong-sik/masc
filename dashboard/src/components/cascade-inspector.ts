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
import { LoadingState, ErrorState, EmptyState } from './common/feedback-state'
import { FilterChips } from './common/filter-chips'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'

// -- Local state -------------------------------------------------

const traceLoading = signal<boolean>(false)
const traceError = signal<string | null>(null)
const traceEvents = signal<CascadeStrategyTraceEvent[]>([])
const traceUpdatedAt = signal<string>('')
const healthLoading = signal<boolean>(false)
const healthError = signal<string | null>(null)
const healthProviders = signal<CascadeHealthProvider[]>([])
const selectedCascade = signal<string>('all')

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

function StrategyTraceTable({ events }: { events: CascadeStrategyTraceEvent[] }) {
  if (events.length === 0) {
    return html`<${EmptyState} message="전략 추적 이벤트가 없습니다" compact />`
  }

  return html`
    <div class="overflow-x-auto rounded border border-card-border/60">
      <table class="w-full text-left text-xs">
        <thead class="bg-[var(--white-3)] text-text-muted">
          <tr>
            <th class="px-3 py-2 font-semibold">시간</th>
            <th class="px-3 py-2 font-semibold">Cascade</th>
            <th class="px-3 py-2 font-semibold">전략</th>
            <th class="px-3 py-2 font-semibold text-right">Cycle</th>
            <th class="px-3 py-2 font-semibold text-right">후보</th>
            <th class="px-3 py-2 font-semibold text-right">백오프(ms)</th>
            <th class="px-3 py-2 font-semibold">결과</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-card-border/40">
          ${events.map(e => html`
            <tr key=${e.ts + e.cascade_name + e.cycle} class="hover:bg-[var(--white-3)] transition-colors">
              <td class="px-3 py-2 text-text-body whitespace-nowrap">
                <${TimeAgo} iso=${new Date(e.ts).toISOString()} />
              </td>
              <td class="px-3 py-2 font-medium text-text-strong">${e.cascade_name}</td>
              <td class="px-3 py-2 text-text-body">${e.strategy}</td>
              <td class="px-3 py-2 text-right tabular-nums text-text-muted">${e.cycle}</td>
              <td class="px-3 py-2 text-right tabular-nums text-text-muted">${e.candidates_in}→${e.candidates_out}</td>
              <td class="px-3 py-2 text-right tabular-nums text-text-muted">${e.backoff_ms}</td>
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

function ProviderHealthTable({ providers }: { providers: CascadeHealthProvider[] }) {
  if (providers.length === 0) {
    return html`<${EmptyState} message="프로바이더 건강 데이터가 없습니다" compact />`
  }

  return html`
    <div class="overflow-x-auto rounded border border-card-border/60">
      <table class="w-full text-left text-xs">
        <thead class="bg-[var(--white-3)] text-text-muted">
          <tr>
            <th class="px-3 py-2 font-semibold">프로바이더</th>
            <th class="px-3 py-2 font-semibold text-right">성공률</th>
            <th class="px-3 py-2 font-semibold text-right">연속 실패</th>
            <th class="px-3 py-2 font-semibold">쿨다운</th>
            <th class="px-3 py-2 font-semibold text-right">이벤트</th>
            <th class="px-3 py-2 font-semibold text-right">평균 지연(ms)</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-card-border/40">
          ${providers.map(p => html`
            <tr key=${p.provider_key} class="hover:bg-[var(--white-3)] transition-colors">
              <td class="px-3 py-2 font-medium text-text-strong">${p.provider_key}</td>
              <td class="px-3 py-2 text-right tabular-nums ${p.success_rate >= 0.9 ? 'text-ok' : p.success_rate >= 0.7 ? 'text-warn' : 'text-bad'}">
                ${Math.round(p.success_rate * 100)}%
              </td>
              <td class="px-3 py-2 text-right tabular-nums ${p.consecutive_failures > 2 ? 'text-bad' : 'text-text-muted'}">
                ${p.consecutive_failures}
              </td>
              <td class="px-3 py-2">
                ${p.in_cooldown
                  ? html`<${StatusBadge} tone="warn">잇데이 출다욘 징햊학<///>`
                  : html`<span class="text-text-muted">-</span>`}
              </td>
              <td class="px-3 py-2 text-right tabular-nums text-text-muted">${p.events_in_window}</td>
              <td class="px-3 py-2 text-right tabular-nums text-text-muted">
                ${p.avg_latency_ms != null ? Math.round(p.avg_latency_ms) : '-'}
              </td>
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
  const chips = [
    { key: 'all', label: '전체' },
    ...names.map(n => ({ key: n, label: n })),
  ]

  return html`
    <div class="flex flex-col gap-5">
      <section class="rounded border border-card-border/70 bg-[rgba(9,14,24,0.88)] p-5" aria-label="Cascade 검사기">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-text-muted">Cascade 검사기</div>
            <h3 class="mt-2 text-[22px] font-semibold tracking-[-0.02em] text-text-strong">
              전략 추적 · 프로바이더 건강도
            </h3>
            <p class="mt-2 text-sm leading-relaxed text-text-muted">
              cascade 의사결정 이력과 프로바이더 상태를 한 화면에서 봅니다.
            </p>
          </div>
        </div>
      </section>

      <section class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-4" aria-label="전략 추적">
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
        ${traceLoading.value
          ? html`<${LoadingState}>이벤트 불러오는 중...<//>`
          : traceError.value
            ? html`<${ErrorState} message=${traceError.value} onRetry=${refreshTrace} />`
            : html`<${StrategyTraceTable} events=${filteredEvents.value} />`
        }
      </section>

      <section class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-4" aria-label="프로바이더 건강도">
        <div class="mb-3">
          <div class="text-2xs font-semibold uppercase tracking-5 text-text-muted">프로바이더</div>
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
