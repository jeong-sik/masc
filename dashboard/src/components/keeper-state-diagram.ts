import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'

import {
  fetchKeeperComposite,
  fetchKeeperTransitions,
  type KeeperCompositeSnapshot,
  type KeeperTransition,
} from '../api/keeper'
import { EmptyState } from './common/empty-state'
import { InlineSpinner } from './common/inline-spinner'
import { CytoscapeFsm } from './common/cytoscape-fsm'
import { buildCompositeFsmSpec } from './keeper-fsm-specs'
import type { KeeperPhase } from '../types'

interface KeeperStateDiagramProps {
  keeperName: string
  currentPhase?: KeeperPhase | string | null
}

const PHASE_ID_MAP: Record<string, string> = {
  Offline: 'Offline',
  Running: 'Running',
  Failing: 'Failing',
  Overflowed: 'Overflowed',
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
  overflowed: 'Overflowed',
  compacting: 'Compacting',
  handing_off: 'HandingOff',
  paused: 'Paused',
  draining: 'Draining',
  stopped: 'Stopped',
  crashed: 'Crashed',
  restarting: 'Restarting',
  dead: 'Dead',
}

const INVARIANT_LABELS: Array<[keyof KeeperCompositeSnapshot['invariants'], string]> = [
  ['phase_turn_alignment', 'Phase ⇔ Turn'],
  ['no_cascade_before_measurement', 'Cascade ordering'],
  ['compaction_atomicity', 'Compaction atomic'],
  ['event_priority_monotone', 'Event priority'],
]

function normalizePhase(phase: string | null | undefined): string | null {
  if (!phase) return null
  return PHASE_ID_MAP[phase] ?? phase
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

function badgeTone(ok: boolean): string {
  return ok
    ? 'border-[rgba(34,197,94,0.24)] bg-[var(--emerald-8)] text-[var(--ok)]'
    : 'border-[rgba(239,68,68,0.24)] bg-[var(--bad-10)] text-[var(--bad)]'
}

export function KeeperStateDiagramPanel({ keeperName, currentPhase }: KeeperStateDiagramProps) {
  const [snapshot, setSnapshot] = useState<KeeperCompositeSnapshot | null>(null)
  const [transitions, setTransitions] = useState<KeeperTransition[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setError(null)

    Promise.allSettled([
      fetchKeeperComposite(keeperName, { signal: controller.signal }),
      fetchKeeperTransitions(keeperName, 5, { signal: controller.signal }),
    ])
      .then(([snapshotResult, transitionsResult]) => {
        if (controller.signal.aborted) return

        if (snapshotResult.status === 'fulfilled') {
          setSnapshot(snapshotResult.value)
        } else {
          setSnapshot(null)
          setError(snapshotResult.reason instanceof Error ? snapshotResult.reason.message : 'composite fetch failed')
        }

        if (transitionsResult.status === 'fulfilled') {
          setTransitions(transitionsResult.value.transitions ?? [])
        } else {
          setTransitions([])
        }

        setLoading(false)
      })
      .catch(err => {
        if (controller.signal.aborted) return
        setError(err instanceof Error ? err.message : 'composite fetch failed')
        setLoading(false)
      })

    return () => { controller.abort() }
  }, [keeperName])

  const keeperPhase = normalizePhase(currentPhase)
  const compositePhase = normalizePhase(snapshot?.phase)
  const phaseMismatch = Boolean(keeperPhase && compositePhase && keeperPhase !== compositePhase)

  const compositeSpec = useMemo(
    () => snapshot
      ? buildCompositeFsmSpec({
          phase: snapshot.phase,
          turnPhase: snapshot.turn_phase,
          decisionStage: snapshot.decision.stage,
          cascadeState: snapshot.cascade.state,
          compactionStage: snapshot.compaction.stage,
        })
      : null,
    [snapshot],
  )

  if (loading) {
    return html`
      <div class="flex items-center justify-center gap-2 py-6 text-[11px] text-[var(--text-dim)]">
        <${InlineSpinner} />
        composite lifecycle 로딩중
      </div>
    `
  }

  if (error || !snapshot || !compositeSpec) {
    return html`<${EmptyState} message=${error ?? 'composite lifecycle 없음'} compact />`
  }

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex flex-wrap items-center gap-2 text-[10px] text-[var(--text-dim)]">
        <span class="inline-flex items-center rounded-sm border border-[var(--accent-30)] bg-[var(--accent-10)] px-2 py-0.5 text-[var(--accent)]">
          composite ${snapshot.phase}
        </span>
        ${keeperPhase ? html`
          <span class="inline-flex items-center rounded-sm border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5">
            keeper ${keeperPhase}
          </span>
        ` : null}
        <span class="inline-flex items-center rounded-sm border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5">
          KTC ${snapshot.turn_phase}
        </span>
        <span class="inline-flex items-center rounded-sm border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5">
          KDP ${snapshot.decision.stage}
        </span>
        <span class="inline-flex items-center rounded-sm border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5">
          KCL ${snapshot.cascade.state}
        </span>
        <span class="inline-flex items-center rounded-sm border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5">
          KMC ${snapshot.compaction.stage}
        </span>
        ${transitions.length > 0 ? html`
          <span class="inline-flex items-center rounded-sm border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5">
            observed ${transitions.length} transitions
          </span>
        ` : null}
      </div>

      ${phaseMismatch ? html`
        <div class="rounded border border-[var(--warn-24)] bg-[var(--warn-8)] px-3 py-2 text-[11px] leading-[1.5] text-[var(--text-body)]">
          keeper row phase와 composite snapshot phase가 다릅니다. composite snapshot을 authoritative runtime-truth로 사용합니다.
        </div>
      ` : null}

      <div>
        <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] mb-2">Composite Lifecycle (KSM · KTC · KDP · KCL · KMC)</div>
        <${CytoscapeFsm} spec=${compositeSpec} height="320px" />
      </div>

      <div class="grid gap-2 md:grid-cols-2">
        ${INVARIANT_LABELS.map(([key, label]) => {
          const ok = snapshot.invariants[key]
          return html`
            <div class=${`rounded border px-3 py-2 text-[11px] leading-[1.5] ${badgeTone(ok)}`}>
              <div class="font-semibold">${label}</div>
              <div class="mt-1 font-mono">${ok ? 'ok' : 'violated'}</div>
            </div>
          `
        })}
      </div>

      ${transitions.length > 0 ? html`
        <div class="grid gap-2">
          <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">Observed transitions</div>
          ${transitions.map(transition => html`
            <div class="rounded border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2 text-[11px] leading-[1.5] text-[var(--text-body)]">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-mono text-[var(--text-strong)]">${normalizePhase(transition.prev_phase) ?? transition.prev_phase}</span>
                <span class="text-[var(--text-dim)]">→</span>
                <span class="font-mono text-[var(--accent)]">${normalizePhase(transition.new_phase) ?? transition.new_phase}</span>
                <span class="rounded-sm border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5 text-[10px] text-[var(--text-muted)]">
                  ${transitionType(transition.selected_event)}
                </span>
              </div>
            </div>
          `)}
        </div>
      ` : null}
    </div>
  `
}
