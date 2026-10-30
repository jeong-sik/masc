// Tool Monitor Reactivity board — keeper-v2 monitor-more design (TmReactivity).
//
// Design vocabulary: .tm-board with .ia-filters view switch; views render
// .ai-tablewrap/.ai-table (health grid with .tm-pausedot), .tm-time/.tm-time-row
// with .tm-tr (phase transitions) or .ai-b (lifecycle events), and
// .tm-ok / .tm-paused-list/.tm-paused-card/.tm-blk (paused keepers).
//
// Live data (mark, don't fake):
//   - health grid + paused view → `keepers` store (dashboard keeper registry)
//   - phase transitions        → /api/v1/keepers/:name/transitions
//   - lifecycle events         → /api/v1/keepers/:name/lifecycle

import { html } from 'htm/preact'
import { signal, useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { keepers, refreshShell } from '../../store'
import {
  fetchKeeperLifecycle,
  fetchKeeperTransitions,
  type KeeperLifecycleEvent,
  type KeeperTransition,
} from '../../api/keeper'
import { isKeeperPaused } from '../../lib/keeper-predicates'
import { eventLabel } from '../keeper-phase-strip'
import { lifecycleEventLabel, lifecycleEventTone } from '../keeper-lifecycle-timeline'

type ReactivityView = 'health' | 'lifecycle' | 'events' | 'pause'

const REACTIVITY_VIEWS: Array<{ id: ReactivityView; label: string }> = [
  { id: 'health', label: '상태 그리드' },
  { id: 'lifecycle', label: '상태 전환' },
  { id: 'events', label: '생명주기 이벤트' },
  { id: 'pause', label: '일시정지' },
]

interface TransitionRow {
  atMs: number
  keeper: string
  from: string
  to: string
  by: string
}

interface LifecycleRow {
  atMs: number
  event: string
  keeper: string
  detail: string
}

const transitionRows = signal<TransitionRow[]>([])
const lifecycleRows = signal<LifecycleRow[]>([])
const timelineLoading = signal(false)

function flattenTransitions(keeper: string, transitions: KeeperTransition[]): TransitionRow[] {
  return transitions.map(t => ({
    atMs: t.wall_clock_at_decision * 1000,
    keeper,
    from: t.prev_phase,
    to: t.new_phase,
    by: t.event_type ?? eventLabel(t.selected_event),
  }))
}

function flattenLifecycle(keeper: string, events: KeeperLifecycleEvent[]): LifecycleRow[] {
  return events.map(ev => ({
    atMs: ev.ts * 1000,
    event: ev.event,
    keeper,
    detail: ev.detail,
  }))
}

async function refreshReactivityTimelines(): Promise<void> {
  const names = keepers.value.map(k => k.name)
  timelineLoading.value = true
  try {
    if (names.length === 0) {
      transitionRows.value = []
      lifecycleRows.value = []
      return
    }
    const [transitions, lifecycles] = await Promise.all([
      Promise.all(names.map(name =>
        fetchKeeperTransitions(name, 30)
          .then(r => flattenTransitions(name, r.transitions))
          .catch((err: unknown) => {
            console.warn('[tool-monitor-reactivity] fetchKeeperTransitions failed', { name, err })
            return [] as TransitionRow[]
          }),
      )),
      Promise.all(names.map(name =>
        fetchKeeperLifecycle(name, 30)
          .then(r => flattenLifecycle(name, r.events))
          .catch((err: unknown) => {
            console.warn('[tool-monitor-reactivity] fetchKeeperLifecycle failed', { name, err })
            return [] as LifecycleRow[]
          }),
      )),
    ])
    transitionRows.value = transitions.flat().sort((a, b) => b.atMs - a.atMs).slice(0, 40)
    lifecycleRows.value = lifecycles.flat().sort((a, b) => b.atMs - a.atMs).slice(0, 40)
  } finally {
    timelineLoading.value = false
  }
}

function hhmm(ms: number): string {
  const d = new Date(ms)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

function HealthGrid() {
  const all = keepers.value
  if (all.length === 0) {
    return html`<div class="dim">등록된 키퍼 없음</div>`
  }
  return html`
    <div class="ai-tablewrap">
      <table class="ai-table">
        <thead>
          <tr><th>키퍼</th><th>단계</th><th>활동</th><th>마지막 활동</th><th class="r">회전 수</th></tr>
        </thead>
        <tbody>
          ${all.map(k => {
            const paused = isKeeperPaused(k)
            return html`
              <tr key=${k.name}>
                <td class="mono">${k.name}</td>
                <td>
                  ${k.lifecycle_phase ?? k.phase ?? '—'}
                  ${paused ? html`<span class="tm-pausedot">⏸ 일시정지</span>` : null}
                </td>
                <td class="dim">${k.pipeline_stage ?? '—'}</td>
                <td class="mono dim">${k.last_activity_ago_s != null ? `${Math.round(k.last_activity_ago_s)}s 전` : '—'}</td>
                <td class="mono r dim">${k.total_turns ?? k.turn_count ?? '—'}</td>
              </tr>
            `
          })}
        </tbody>
      </table>
    </div>
  `
}

function LifecycleTimeline() {
  const rows = transitionRows.value
  if (rows.length === 0) {
    return html`<div class="dim">${timelineLoading.value ? '불러오는 중…' : '기록된 상태 전환 없음'}</div>`
  }
  return html`
    <div class="tm-time">
      ${rows.map(t => html`
        <div key=${`${t.keeper}-${t.atMs}-${t.to}`} class="tm-time-row">
          <span class="mono dim">${hhmm(t.atMs)}</span>
          <span class="mono">${t.keeper}</span>
          <span class="tm-tr"><b>${t.from}</b> → <b>${t.to}</b></span>
          <span class="dim">${t.by}</span>
        </div>
      `)}
    </div>
  `
}

function LifecycleEvents() {
  const rows = lifecycleRows.value
  if (rows.length === 0) {
    return html`<div class="dim">${timelineLoading.value ? '불러오는 중…' : '기록된 생명주기 이벤트 없음'}</div>`
  }
  return html`
    <div class="tm-time">
      ${rows.map(t => {
        const tone = lifecycleEventTone(t.event)
        return html`
          <div key=${`${t.keeper}-${t.atMs}-${t.event}`} class="tm-time-row">
            <span class="mono dim">${hhmm(t.atMs)}</span>
            <span class="ai-b ${tone === 'neutral' || tone === 'info' ? '' : tone}">${lifecycleEventLabel(t.event)}</span>
            <span class="mono">${t.keeper}</span>
            <span class="dim">${t.detail}</span>
          </div>
        `
      })}
    </div>
  `
}

function PausedKeepers() {
  const paused = keepers.value.filter(isKeeperPaused)
  if (paused.length === 0) {
    return html`<div class="tm-ok">✓ 일시정지된 키퍼 없음 — 모든 키퍼가 정상 운영 중입니다</div>`
  }
  return html`
    <div class="tm-paused-list">
      ${paused.map(k => {
        return html`
          <div key=${k.name} class="tm-paused-card">
            <span class="mono">⏸ ${k.name}</span>
            <span class="dim">${k.lifecycle_phase ?? k.phase ?? '—'}</span>
          </div>
        `
      })}
    </div>
  `
}

export function ToolMonitorReactivityBoard() {
  const view = useSignal<ReactivityView>('health')

  useEffect(() => {
    void refreshReactivityTimelines()
    void refreshShell({ force: true })
  }, [])

  return html`
    <div class="tm-board" data-testid="tool-monitor-reactivity">
      <div class="ia-filters">
        ${REACTIVITY_VIEWS.map(v => html`
          <button
            key=${v.id}
            type="button"
            class="ia-filter ${view.value === v.id ? 'on' : ''}"
            aria-pressed=${view.value === v.id}
            onClick=${() => { view.value = v.id }}
          >${v.label}</button>
        `)}
      </div>
      ${view.value === 'health' ? html`<${HealthGrid} />`
        : view.value === 'lifecycle' ? html`<${LifecycleTimeline} />`
        : view.value === 'events' ? html`<${LifecycleEvents} />`
        : html`<${PausedKeepers} />`}
    </div>
  `
}
