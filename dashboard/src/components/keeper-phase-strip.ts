// Keeper Phase Transition Timeline — visual timeline of FSM phase transitions

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { keepers } from '../store'
import { fetchKeeperTransitions, type KeeperTransition, type KeeperTransitionsResponse } from '../api/keeper'
import { TimeAgo } from './common/time-ago'

const transitionData = signal<Map<string, KeeperTransitionsResponse>>(new Map())
const loading = signal(false)

const PHASE_COLORS: Record<string, string> = {
  Running: 'var(--ok)',
  Compacting: '#fbbf24',
  HandingOff: '#22d3ee',
  Failing: 'var(--bad)',
  Crashed: '#ef4444',
  Dead: '#6b7280',
  Paused: '#a78bfa',
  Draining: '#fb923c',
  Restarting: '#38bdf8',
  Stopped: '#9ca3af',
  Offline: '#4b5563',
}

function phaseColor(phase: string): string {
  return PHASE_COLORS[phase] ?? '#6b7280'
}

function phaseBgClass(phase: string): string {
  switch (phase) {
    case 'Running': return 'bg-[var(--ok)]/15 text-[var(--ok)]'
    case 'Failing': case 'Crashed': return 'bg-[var(--bad)]/15 text-[var(--bad-light)]'
    case 'Compacting': return 'bg-[#fbbf24]/15 text-[#fbbf24]'
    case 'HandingOff': return 'bg-[#22d3ee]/15 text-[#22d3ee]'
    case 'Paused': return 'bg-[#a78bfa]/15 text-[#a78bfa]'
    default: return 'bg-[var(--white-6)] text-[var(--text-muted)]'
  }
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
        <div class="rounded-lg border border-[var(--card-border)] bg-[var(--card)] px-3 py-2 shadow-lg text-[11px] whitespace-nowrap">
          <div class="font-semibold">${t.prev_phase} → ${t.new_phase}</div>
          <div class="text-[var(--text-muted)] mt-0.5">${t.selected_event}</div>
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
    <div class="flex items-center gap-3 py-2 px-3 rounded-lg border border-[var(--white-6)] bg-[var(--white-3)]">
      <div class="w-24 shrink-0">
        <div class="text-[13px] font-semibold text-[var(--text-strong)] truncate">${name}</div>
        <div class="inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-medium mt-1 ${phaseBgClass(phase)}">
          ${phase}
        </div>
      </div>
      <div class="flex-1 flex items-center gap-1.5 overflow-x-auto min-h-[24px]">
        ${transitions.length === 0
          ? html`<span class="text-[11px] text-[var(--text-muted)]">no transitions</span>`
          : transitions.map((t, i) => html`
              <${TransitionDot} t=${t} idx=${i} />
              ${i < transitions.length - 1 ? html`<div class="w-3 h-px bg-[var(--white-10)]" />` : null}
            `)
        }
      </div>
      <div class="shrink-0 text-[11px] text-[var(--text-muted)] tabular-nums">
        ${transitions.length} transitions
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
    return html`<div class="text-[12px] text-[var(--text-muted)] py-4 text-center">Phase timeline loading...</div>`
  }

  if (keeperList.length === 0) {
    return html`<div class="text-[12px] text-[var(--text-muted)] py-4 text-center">No keepers registered</div>`
  }

  return html`
    <div class="flex flex-col gap-2">
      <div class="flex items-center justify-between mb-1">
        <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">Phase Transitions (recent 30)</div>
        <button
          type="button"
          class="text-[11px] text-[var(--text-dim)] hover:text-[var(--text-body)] transition-colors"
          onClick=${() => { void loadAll() }}
        >refresh</button>
      </div>
      ${keeperList.map(k => {
        const d = data.get(k.name)
        return d
          ? html`<${KeeperStrip} name=${k.name} data=${d} key=${k.name} />`
          : html`
            <div class="flex items-center gap-3 py-2 px-3 rounded-lg border border-[var(--white-6)] bg-[var(--white-3)]" key=${k.name}>
              <div class="w-24 text-[13px] font-semibold text-[var(--text-strong)] truncate">${k.name}</div>
              <span class="text-[11px] text-[var(--text-muted)]">no data</span>
            </div>
          `
      })}
    </div>
  `
}

export { loadAll as refreshKeeperPhaseTimeline }
