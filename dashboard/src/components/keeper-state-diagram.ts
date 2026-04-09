import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'

import {
  fetchKeeperStateDiagram,
  fetchKeeperTransitions,
  type KeeperTransition,
} from '../api/keeper'
import { EmptyState } from './common/empty-state'
import { MermaidGraph } from './common/mermaid-graph'
import type { KeeperPhase } from '../types'

interface KeeperStateDiagramProps {
  keeperName: string
  currentPhase?: KeeperPhase | string | null
}

const BUFFER_PHASES = new Set(['Failing', 'Compacting', 'HandingOff', 'Draining', 'Restarting'])
const TERMINAL_PHASES = new Set(['Stopped', 'Dead'])

const PHASE_ID_MAP: Record<string, string> = {
  Offline: 'Offline',
  Running: 'Running',
  Failing: 'Failing',
  Compacting: 'Compacting',
  HandingOff: 'HandingOff',
  Draining: 'Draining',
  Paused: 'Paused',
  Stopped: 'Stopped',
  Crashed: 'Crashed',
  Restarting: 'Restarting',
  Dead: 'Dead',
  offline: 'Offline',
  running: 'Running',
  failing: 'Failing',
  compacting: 'Compacting',
  handing_off: 'HandingOff',
  paused: 'Paused',
  draining: 'Draining',
  stopped: 'Stopped',
  crashed: 'Crashed',
  restarting: 'Restarting',
  dead: 'Dead',
}

function normalizePhase(phase: string | null | undefined): string | null {
  if (!phase) return null
  return PHASE_ID_MAP[phase] ?? null
}

function phaseClass(phase: string | null): 'active' | 'buffer' | 'terminal' {
  if (!phase) return 'active'
  if (TERMINAL_PHASES.has(phase)) return 'terminal'
  if (BUFFER_PHASES.has(phase)) return 'buffer'
  return 'active'
}

function rewriteMermaidHighlight(source: string, phase: string | null): string {
  if (!source.trim()) return source
  const lines = source
    .split('\n')
    .filter(line => !/^\s*class\s+[A-Za-z0-9_]+\s+(active|buffer|terminal)\s*$/.test(line))
  const target = normalizePhase(phase)
  if (!target) return lines.join('\n')
  lines.push(`    class ${target} ${phaseClass(target)}`)
  return lines.join('\n')
}

function transitionType(selectedEvent: unknown): string {
  if (selectedEvent && typeof selectedEvent === 'object' && 'type' in selectedEvent) {
    const raw = (selectedEvent as { type?: unknown }).type
    if (typeof raw === 'string' && raw.trim()) {
      return raw.split('_').join(' ')
    }
  }
  return 'event'
}

function formatPhaseBadgeLabel(phase: string | null | undefined): string {
  return normalizePhase(phase) ?? phase ?? 'unknown'
}

export function KeeperStateDiagramPanel({ keeperName, currentPhase }: KeeperStateDiagramProps) {
  const [mermaid, setMermaid] = useState<string | null>(null)
  const [apiPhase, setApiPhase] = useState<string | null>(null)
  const [transitions, setTransitions] = useState<KeeperTransition[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    setError(null)

    Promise.allSettled([
      fetchKeeperStateDiagram(keeperName),
      fetchKeeperTransitions(keeperName, 5),
    ])
      .then(([diagramResult, transitionsResult]) => {
        if (cancelled) return
        if (diagramResult.status === 'fulfilled') {
          setMermaid(diagramResult.value.mermaid)
          setApiPhase(diagramResult.value.current_phase)
        } else {
          setMermaid(null)
          setApiPhase(null)
          setError(diagramResult.reason instanceof Error ? diagramResult.reason.message : 'state diagram fetch failed')
        }

        if (transitionsResult.status === 'fulfilled') {
          setTransitions(transitionsResult.value.transitions ?? [])
        } else {
          setTransitions([])
        }

        setLoading(false)
      })
      .catch(err => {
        if (cancelled) return
        setError(err instanceof Error ? err.message : 'state diagram fetch failed')
        setLoading(false)
      })

    return () => { cancelled = true }
  }, [keeperName])

  const livePhase = normalizePhase(currentPhase) ?? normalizePhase(apiPhase)
  const registryPhase = normalizePhase(apiPhase)
  const phaseMismatch = Boolean(livePhase && registryPhase && livePhase !== registryPhase)
  const mermaidSource = useMemo(
    () => (mermaid ? rewriteMermaidHighlight(mermaid, livePhase) : null),
    [mermaid, livePhase],
  )

  if (loading) {
    return html`
      <div class="flex items-center justify-center gap-2 py-6 text-[11px] text-[var(--text-dim)]">
        <span class="inline-block h-3 w-3 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin" aria-hidden="true"></span>
        상태 다이어그램 로딩중
      </div>
    `
  }

  if (error || !mermaidSource) {
    return html`<${EmptyState} message=${error ?? '다이어그램 없음'} compact />`
  }

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex flex-wrap items-center gap-2 text-[10px] text-[var(--text-dim)]">
        <span class="inline-flex items-center rounded-full border border-[var(--accent-30)] bg-[var(--accent-10)] px-2 py-0.5 text-[var(--accent)]">
          live phase ${formatPhaseBadgeLabel(livePhase)}
        </span>
        ${registryPhase ? html`
          <span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5">
            registry ${formatPhaseBadgeLabel(registryPhase)}
          </span>
        ` : null}
        ${transitions.length > 0 ? html`
          <span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5">
            observed ${transitions.length} transitions
          </span>
        ` : null}
      </div>

      ${phaseMismatch ? html`
        <div class="rounded-xl border border-[rgba(251,191,36,0.24)] bg-[rgba(251,191,36,0.08)] px-3 py-2 text-[11px] leading-[1.5] text-[var(--text-body)]">
          Mermaid 강조는 execution projection phase를 기준으로 다시 칠했습니다. registry phase와 다르므로 현재는 다이어그램의 경로보다 아래 observed transition 기록을 더 신뢰하는 편이 안전합니다.
        </div>
      ` : null}

      <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
        <${MermaidGraph}
          source=${mermaidSource}
          prefix="keeper-state-diagram"
          diagramClass="[&_svg]:max-w-full [&_svg]:mx-auto"
          minHeightClass="min-h-[120px]"
        />
      </div>

      ${transitions.length > 0 ? html`
        <div class="grid gap-2">
          <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">Observed transitions</div>
          ${transitions.map(transition => html`
            <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2 text-[11px] leading-[1.5] text-[var(--text-body)]">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-mono text-[var(--text-strong)]">${formatPhaseBadgeLabel(transition.prev_phase)}</span>
                <span class="text-[var(--text-dim)]">→</span>
                <span class="font-mono text-[var(--accent)]">${formatPhaseBadgeLabel(transition.new_phase)}</span>
                <span class="rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5 text-[10px] text-[var(--text-muted)]">${transitionType(transition.selected_event)}</span>
              </div>
            </div>
          `)}
        </div>
      ` : null}
    </div>
  `
}
