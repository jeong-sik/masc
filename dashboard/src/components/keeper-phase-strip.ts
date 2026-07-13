// Keeper Phase Transition Timeline — visual timeline of FSM phase transitions

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { keepers } from '../store'
import { fetchKeeperTransitions, type KeeperTransition, type KeeperTransitionsResponse } from '../api/keeper'
import { TimeAgo } from './common/time-ago'
import { LoadingState } from './common/feedback-state'
import { getPhaseStyle } from './keeper-phase-indicator'

const transitionData = signal<Map<string, KeeperTransitionsResponse>>(new Map())
const loading = signal(false)

function phaseColor(phase: string): string {
  return getPhaseStyle(phase).color
}

function phaseInlineStyle(phase: string): string {
  const style = getPhaseStyle(phase)
  return `color: ${style.color}; background: ${style.bg}; border: 1px solid ${style.border};`
}

function transitionColor(t: KeeperTransition): string {
  return phaseColor(t.new_phase)
}

/** selected_event comes as object {type: "...", ...} from the server */
export function eventLabel(event: unknown): string {
  if (typeof event === 'string') return event
  if (event && typeof event === 'object' && 'type' in event) {
    const type = (event as Record<string, unknown>).type
    if (type != null) return String(type)
  }
  return '?'
}

export async function refreshKeeperPhaseTimeline() {
  const names = keepers.value.map(k => k.name)
  if (names.length === 0) return
  loading.value = true
  try {
    // P2 silent-failure fix: a partial fleet outage previously produced
    // a phase-strip with random keepers missing — visually identical to
    // "those keepers have no transitions yet" — and operators had no way
    // to tell.  Per-name catch now logs which keeper's fetch failed so
    // the gap pattern is diagnosable from DevTools, while the strip
    // still degrades gracefully for the keepers that did succeed.
    const results = await Promise.all(
      names.map(name =>
        fetchKeeperTransitions(name, 30).catch((err: unknown) => {
          console.warn('[keeper-phase-strip] fetchKeeperTransitions failed', { name, err })
          return null
        }),
      ),
    )
    const next = new Map<string, KeeperTransitionsResponse>()
    for (let i = 0; i < names.length; i++) {
      const r = results[i]
      if (r) next.set(names[i]!, r)
    }
    transitionData.value = next
  } finally {
    loading.value = false
  }
}

function TransitionDot({ t, idx }: { t: KeeperTransition; idx: number }) {
  const color = transitionColor(t)
  return html`
    <div class="group relative flex flex-col items-center v2-monitoring-row" key=${idx}>
      <div
        class="w-3 h-3 rounded-full border-2 cursor-default transition-transform hover:scale-125"
        style="border-color: ${color}; background: ${color}33"
      />
      <div class="absolute bottom-full mb-2 hidden group-hover:flex flex-col items-center z-10">
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 shadow-[var(--shadow-1)] text-2xs whitespace-nowrap">
          <div class="font-semibold">${t.prev_phase} → ${t.new_phase}</div>
          <div class="text-[var(--color-fg-muted)] mt-0.5">${t.event_type ?? eventLabel(t.selected_event)}</div>
          <div class="mt-1 text-[var(--color-fg-primary)]">${t.transition_outcome}</div>
          <div class="text-[var(--color-fg-muted)]"><${TimeAgo} timestamp=${t.wall_clock_at_decision * 1000} /></div>
        </div>
      </div>
    </div>
  `
}

function KeeperStrip({ name, data }: { name: string; data: KeeperTransitionsResponse }) {
  const phase = data.current_phase ?? 'Offline'
  const transitions = data.transitions

  return html`
    <div class="flex items-center gap-3 py-2 px-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] v2-monitoring-row" role="listitem" aria-label="${name}: ${getPhaseStyle(phase).label}, 전환 ${transitions.length}건">
      <div class="w-24 shrink-0">
        <div class="text-sm font-semibold text-[var(--color-fg-secondary)] truncate">${name}</div>
        <div
          class="inline-flex items-center rounded-[var(--r-1)] px-2 py-0.5 text-3xs font-semibold tracking-wide mt-1"
          style="${phaseInlineStyle(phase)}"
          role="status"
        >
          ${getPhaseStyle(phase).icon} ${getPhaseStyle(phase).label}
        </div>
      </div>
      <div class="flex-1 flex items-center gap-1.5 overflow-x-auto min-h-6">
        ${transitions.length === 0
          ? html`<span class="text-2xs text-[var(--color-fg-muted)]">전환 없음</span>`
          : transitions.map((t, i) => html`
              <${TransitionDot} t=${t} idx=${i} />
              ${i < transitions.length - 1 ? html`<div class="w-3 h-px bg-[var(--color-bg-hover)]" />` : null}
            `)
        }
      </div>
      <div class="shrink-0 text-2xs text-[var(--color-fg-muted)] tabular-nums">
        ${transitions.length}건
      </div>
    </div>
  `
}

export function KeeperPhaseTimeline() {
  useEffect(() => { void refreshKeeperPhaseTimeline() }, [])

  const data = transitionData.value
  const isLoading = loading.value
  const keeperList = keepers.value

  if (isLoading && data.size === 0) {
    return html`<${LoadingState}>페이즈 타임라인 불러오는 중...<//>`
  }

  if (keeperList.length === 0) {
    return html`<div class="text-xs text-[var(--color-fg-muted)] py-4 text-center v2-monitoring-panel">등록된 키퍼 없음</div>`
  }

  return html`
    <div class="flex flex-col gap-2 v2-monitoring-surface" role="list" aria-label="키퍼 페이즈 전환 타임라인">
      <div class="flex items-center justify-between mb-1 v2-monitoring-toolbar">
        <div class="text-2xs text-[var(--color-fg-muted)] uppercase tracking-wider font-medium">페이즈 전환 (최근 30건)</div>
        <button
          type="button"
          class="text-2xs text-[var(--color-fg-disabled)] hover:text-[var(--color-fg-primary)] transition-colors v2-monitoring-action"
          onClick=${() => { void refreshKeeperPhaseTimeline() }}
        >새로고침</button>
      </div>
      ${keeperList.map(k => {
        const d = data.get(k.name)
        return d
          ? html`<${KeeperStrip} name=${k.name} data=${d} key=${k.name} />`
          : html`
            <div class="flex items-center gap-3 py-2 px-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] v2-monitoring-row" key=${k.name}>
              <div class="w-24 text-sm font-semibold text-[var(--color-fg-secondary)] truncate">${k.name}</div>
              <span class="text-2xs text-[var(--color-fg-muted)]">데이터 없음</span>
            </div>
          `
      })}
    </div>
  `
}
