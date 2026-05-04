// Keeper Lifecycle Timeline — visualizes the lifecycle event stream from
// /api/v1/keepers/:name/lifecycle (#12798).
//
// The lifecycle event stream is distinct from the FSM phase-transition
// strip (keeper-phase-strip.ts):
//   • Phase strip   — records FSM transitions (prev_phase → new_phase)
//   • Lifecycle     — records higher-level supervisor events
//     (Started, Reconciled, Restarted, Dead_cleaned, Paused_pruned, etc.)
//
// Both are useful together: the lifecycle timeline shows *why* a phase
// sequence happened (operator pause, auto-resume, restart burst) while
// the phase strip shows *what* happened state-by-state.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { keepers } from '../store'
import {
  fetchKeeperLifecycle,
  type KeeperLifecycleEvent,
  type KeeperLifecycleTimelineResponse,
} from '../api/keeper'
import { TimeAgo } from './common/time-ago'
import { LoadingState } from './common/feedback-state'
import { getPhaseStyle } from './keeper-phase-indicator'
import { toPascalPhase } from './keeper-phase-strip'

// ── Module-level signals ──────────────────────────────────────────────────

const lifecycleData = signal<Map<string, KeeperLifecycleTimelineResponse>>(new Map())
const loading = signal(false)

// ── Lifecycle event categorisation ───────────────────────────────────────

type EventTone = 'ok' | 'warn' | 'bad' | 'info'

/** Map well-known lifecycle event strings to a semantic tone. */
export function lifecycleEventTone(event: string): EventTone {
  const e = event.trim().toLowerCase()
  if (e === 'started' || e === 'reconciled' || e === 'auto_resumed') return 'ok'
  if (e === 'restarted') return 'warn'
  if (e === 'dead_cleaned') return 'bad'
  if (e === 'paused_pruned' || e === 'self_preservation') return 'warn'
  return 'info'
}

function toneStyle(tone: EventTone): { dot: string; label: string } {
  switch (tone) {
    case 'ok':   return { dot: 'var(--color-status-ok)',   label: 'text-[var(--color-status-ok)]' }
    case 'warn': return { dot: 'var(--color-status-warn)', label: 'text-[var(--color-status-warn)]' }
    case 'bad':  return { dot: 'var(--bad-light)',         label: 'text-[var(--bad-light)]' }
    case 'info':
    default:     return { dot: 'var(--color-fg-muted)',    label: 'text-[var(--color-fg-muted)]' }
  }
}

/** Human-readable label for well-known lifecycle event keys. */
export function lifecycleEventLabel(event: string): string {
  switch (event.trim().toLowerCase()) {
    case 'started':           return '기동됨'
    case 'reconciled':        return '재조정됨'
    case 'restarted':         return '재시작됨'
    case 'dead_cleaned':      return '종료 정리됨'
    case 'self_preservation': return '자기보존'
    case 'paused_pruned':     return '일시정지 정리됨'
    case 'auto_resumed':      return '자동 재개됨'
    default:                  return event.replace(/_/g, ' ')
  }
}

// ── Data loading ──────────────────────────────────────────────────────────

async function loadAll() {
  const names = keepers.value.map(k => k.name)
  if (names.length === 0) return
  loading.value = true
  try {
    const results = await Promise.all(
      names.map(name =>
        fetchKeeperLifecycle(name, 30).catch((err: unknown) => {
          console.warn('[keeper-lifecycle-timeline] fetchKeeperLifecycle failed', { name, err })
          return null
        }),
      ),
    )
    const next = new Map<string, KeeperLifecycleTimelineResponse>()
    for (let i = 0; i < names.length; i++) {
      const r = results[i]
      if (r) next.set(names[i]!, r)
    }
    lifecycleData.value = next
  } finally {
    loading.value = false
  }
}

// ── Sub-components ────────────────────────────────────────────────────────

function LifecycleEventRow({ ev }: { ev: KeeperLifecycleEvent }) {
  const tone = lifecycleEventTone(ev.event)
  const style = toneStyle(tone)
  const phaseStyle = ev.phase ? getPhaseStyle(toPascalPhase(ev.phase)) : null

  return html`
    <div
      class="flex items-start gap-3 py-1.5 px-3 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] border border-[var(--color-border-default)]"
      role="listitem"
    >
      <div
        class="mt-1 shrink-0 w-2 h-2 rounded-full"
        style="background: ${style.dot}"
        aria-hidden="true"
      />
      <div class="flex-1 min-w-0">
        <div class="flex flex-wrap items-center gap-2">
          <span class="text-2xs font-semibold ${style.label}">${lifecycleEventLabel(ev.event)}</span>
          ${phaseStyle
            ? html`<span
                class="inline-flex items-center rounded-[var(--r-0)] px-1.5 py-px text-3xs font-semibold"
                style="color: ${phaseStyle.color}; background: ${phaseStyle.bg}; border: 1px solid ${phaseStyle.border}"
              >${phaseStyle.icon} ${phaseStyle.label}</span>`
            : null}
          <span class="text-3xs text-[var(--color-fg-disabled)] tabular-nums ml-auto">
            <${TimeAgo} timestamp=${ev.ts * 1000} />
          </span>
        </div>
        ${ev.detail
          ? html`<div class="mt-0.5 text-3xs text-[var(--color-fg-muted)] leading-snug break-words">${ev.detail}</div>`
          : null}
      </div>
    </div>
  `
}

function KeeperLifecycleRow({
  name,
  data,
}: {
  name: string
  data: KeeperLifecycleTimelineResponse
}) {
  const events = data.events

  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] overflow-hidden"
      role="group"
      aria-label="${name} 생명주기 이벤트"
    >
      <div class="flex items-center justify-between px-3 py-1.5 border-b border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
        <span class="text-xs font-semibold text-[var(--color-fg-secondary)] truncate">${name}</span>
        <span class="text-3xs text-[var(--color-fg-disabled)] tabular-nums shrink-0 ml-2">${events.length}건</span>
      </div>
      ${events.length === 0
        ? html`<div class="px-3 py-2 text-2xs text-[var(--color-fg-muted)]">이벤트 없음</div>`
        : html`
          <div class="flex flex-col gap-1 p-2" role="list">
            ${events.map((ev, i) => html`<${LifecycleEventRow} ev=${ev} key=${i} />`)}
          </div>
        `}
    </div>
  `
}

// ── Public component ──────────────────────────────────────────────────────

export function KeeperLifecycleTimeline() {
  useEffect(() => { void loadAll() }, [])

  const data = lifecycleData.value
  const isLoading = loading.value
  const keeperList = keepers.value

  if (isLoading && data.size === 0) {
    return html`<${LoadingState}>생명주기 이벤트 불러오는 중...<//>`
  }

  if (keeperList.length === 0) {
    return html`<div class="text-xs text-[var(--color-fg-muted)] py-4 text-center">등록된 키퍼 없음</div>`
  }

  return html`
    <div class="flex flex-col gap-3" role="list" aria-label="키퍼 생명주기 타임라인">
      <div class="flex items-center justify-between">
        <div class="text-2xs text-[var(--color-fg-muted)] uppercase tracking-wider font-medium">
          생명주기 이벤트 (최근 30건)
        </div>
        <button
          type="button"
          class="text-2xs text-[var(--color-fg-disabled)] hover:text-[var(--color-fg-primary)] transition-colors"
          onClick=${() => { void loadAll() }}
        >새로고침</button>
      </div>
      ${keeperList.map(k => {
        const d = data.get(k.name)
        return d
          ? html`<${KeeperLifecycleRow} name=${k.name} data=${d} key=${k.name} />`
          : html`
            <div
              class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-3 py-2"
              key=${k.name}
            >
              <span class="text-xs font-semibold text-[var(--color-fg-secondary)]">${k.name}</span>
              <span class="ml-2 text-2xs text-[var(--color-fg-muted)]">데이터 없음</span>
            </div>
          `
      })}
    </div>
  `
}

export { loadAll as refreshKeeperLifecycleTimeline }
