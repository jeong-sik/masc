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

/** Server sends lowercase (e.g. "running", "handing_off"); PHASE_STYLES uses PascalCase. */
export function toPascalPhase(phase: string): string {
  return phase.toLowerCase()
    .replace(/_([a-z])/g, (_, c: string) => c.toUpperCase())
    .replace(/^./, s => s.toUpperCase())
}

function phaseColor(phase: string): string {
  return getPhaseStyle(toPascalPhase(phase)).color
}

function phaseInlineStyle(phase: string): string {
  const style = getPhaseStyle(toPascalPhase(phase))
  return `color: ${style.color}; background: ${style.bg}; border: 1px solid ${style.border};`
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

async function loadAll() {
  const names = keepers.value.map(k => k.name)
  if (names.length === 0) return
  loading.value = true
  try {
    const results = await Promise.all(
      names.map(name => fetchKeeperTransitions(name, 30).catch(() => null)),
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
  const color = phaseColor(t.new_phase)
  return html`
    <div class="group relative flex flex-col items-center" key=${idx}>
      <div
        class="w-3 h-3 rounded-full border-2 cursor-default transition-transform hover:scale-125"
        style="border-color: ${color}; background: ${color}33"
      />
      <div class="absolute bottom-full mb-2 hidden group-hover:flex flex-col items-center z-10">
        <div class="rounded border border-[var(--card-border)] bg-[var(--card)] px-3 py-2 shadow-sm text-[11px] whitespace-nowrap">
          <div class="font-semibold">${t.prev_phase} → ${t.new_phase}</div>
          <div class="text-[var(--text-muted)] mt-0.5">${eventLabel(t.selected_event)}</div>
          <div class="text-[var(--text-muted)]"><${TimeAgo} timestamp=${t.wall_clock_at_decision * 1000} /></div>
        </div>
      </div>
    </div>
  `
}

function KeeperStrip({ name, data }: { name: string; data: KeeperTransitionsResponse }) {
  const phase = data.current_phase ?? 'Offline'
  const transitions = data.transitions

  return html`
    <div class="flex items-center gap-3 py-2 px-3 rounded border border-[var(--white-6)] bg-[var(--white-3)]">
      <div class="w-24 shrink-0">
        <div class="text-[13px] font-semibold text-[var(--text-strong)] truncate">${name}</div>
        <div
          class="inline-flex items-center rounded px-2 py-0.5 text-[10px] font-semibold tracking-wide mt-1"
          style="${phaseInlineStyle(phase)}"
        >
          ${getPhaseStyle(toPascalPhase(phase)).icon} ${getPhaseStyle(toPascalPhase(phase)).label}
        </div>
      </div>
      <div class="flex-1 flex items-center gap-1.5 overflow-x-auto min-h-[24px]">
        ${transitions.length === 0
          ? html`<span class="text-[11px] text-[var(--text-muted)]">전환 없음</span>`
          : transitions.map((t, i) => html`
              <${TransitionDot} t=${t} idx=${i} />
              ${i < transitions.length - 1 ? html`<div class="w-3 h-px bg-[var(--white-10)]" />` : null}
            `)
        }
      </div>
      <div class="shrink-0 text-[11px] text-[var(--text-muted)] tabular-nums">
        ${transitions.length}건
      </div>
    </div>
  `
}

export function KeeperPhaseTimeline() {
  useEffect(() => { void loadAll() }, [])

  const data = transitionData.value
  const isLoading = loading.value
  const keeperList = keepers.value

  if (isLoading && data.size === 0) {
    return html`<${LoadingState}>페이즈 타임라인 불러오는 중...<//>`
  }

  if (keeperList.length === 0) {
    return html`<div class="text-[12px] text-[var(--text-muted)] py-4 text-center">등록된 키퍼 없음</div>`
  }

  return html`
    <div class="flex flex-col gap-2">
      <div class="flex items-center justify-between mb-1">
        <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">페이즈 전환 (최근 30건)</div>
        <button
          type="button"
          class="text-[11px] text-[var(--text-dim)] hover:text-[var(--text-body)] transition-colors"
          onClick=${() => { void loadAll() }}
        >새로고침</button>
      </div>
      ${keeperList.map(k => {
        const d = data.get(k.name)
        return d
          ? html`<${KeeperStrip} name=${k.name} data=${d} key=${k.name} />`
          : html`
            <div class="flex items-center gap-3 py-2 px-3 rounded border border-[var(--white-6)] bg-[var(--white-3)]" key=${k.name}>
              <div class="w-24 text-[13px] font-semibold text-[var(--text-strong)] truncate">${k.name}</div>
              <span class="text-[11px] text-[var(--text-muted)]">데이터 없음</span>
            </div>
          `
      })}
    </div>
  `
}

export { loadAll as refreshKeeperPhaseTimeline }
