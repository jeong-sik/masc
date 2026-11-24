import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'

import {
  fetchKeeperComposite,
  fetchKeeperTransitions,
  type KeeperCompositeSnapshot,
  type KeeperTransition,
} from '../api/keeper'
import { isRecord } from './common/normalize'
import { EmptyState } from './common/feedback-state'
import { InlineSpinner } from './common/inline-spinner'
import { displayState, INVARIANT_LABELS } from '../lib/keeper-fsm-labels'
import type { KeeperCompositeInvariants } from '../api/schemas/keeper-composite'
import {
  normalizePhaseDiagnosis,
  PhaseConditionsPanel,
} from './phase-conditions-panel'
import { toKeeperPhase } from '../keeper-store-normalize'

interface KeeperStateDiagramProps {
  keeperName: string
  snapshot?: KeeperCompositeSnapshot | null
}

function PhaseBadge({ accent, children }: { accent?: boolean; children: unknown }) {
  const cls = accent
    ? 'inline-flex items-center rounded-[var(--r-0)] border border-[var(--accent-30)] bg-[var(--accent-10)] px-2 py-0.5 text-[var(--color-accent-fg)]'
    : 'inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5'
  return html`<span class="${cls}">${children}</span>`
}

export function transitionType(selectedEvent: unknown): string {
  if (selectedEvent && typeof selectedEvent === 'object' && 'type' in selectedEvent) {
    const raw = (selectedEvent as { type?: unknown }).type
    if (typeof raw === 'string' && raw.trim()) {
      return raw.split('_').join(' ')
    }
  }
  return 'event'
}

export function badgeTone(ok: boolean): string {
  return ok
    ? 'border-[var(--ok-border)] bg-[var(--ok-soft)] text-[var(--color-status-ok)]'
    : 'border-[var(--err-border)] bg-[var(--bad-10)] text-[var(--color-status-err)]'
}

function snapshotPhaseDiagnosis(snapshot: KeeperCompositeSnapshot): unknown {
  return isRecord(snapshot) ? snapshot.phase_diagnosis : undefined
}

export function KeeperStateDiagramPanel({ keeperName, snapshot: externalSnapshot }: KeeperStateDiagramProps) {
  const [internalSnapshot, setInternalSnapshot] = useState<KeeperCompositeSnapshot | null>(null)
  const snapshot = externalSnapshot ?? internalSnapshot
  const [transitions, setTransitions] = useState<KeeperTransition[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setError(null)

    const compositePromise: Promise<KeeperCompositeSnapshot | null> = externalSnapshot !== undefined
      ? Promise.resolve(externalSnapshot)
      : fetchKeeperComposite(keeperName, { signal: controller.signal })

    Promise.allSettled([
      compositePromise,
      fetchKeeperTransitions(keeperName, 5, { signal: controller.signal }),
    ])
      .then(([snapshotResult, transitionsResult]) => {
        if (controller.signal.aborted) return

        if (snapshotResult.status === 'fulfilled') {
          setInternalSnapshot(snapshotResult.value)
        } else {
          setInternalSnapshot(null)
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

  const phaseDiagnosis = useMemo(
    () => snapshot ? normalizePhaseDiagnosis(snapshotPhaseDiagnosis(snapshot)) : null,
    [snapshot],
  )

  if (loading) {
    return html`
      <div class="flex items-center justify-center gap-2 py-6 text-2xs text-[var(--color-fg-disabled)] v2-monitoring-panel" role="status">
        <${InlineSpinner} />
        composite lifecycle 로딩중
      </div>
    `
  }

  if (error || !snapshot) {
    return html`<${EmptyState} message=${error ?? 'composite lifecycle 없음'} compact />`
  }

  return html`
    <div class="flex flex-col gap-3 v2-monitoring-panel">
      <div class="flex flex-wrap items-center gap-2 text-3xs text-[var(--color-fg-disabled)] v2-monitoring-toolbar">
        <${PhaseBadge} accent>composite ${displayState(snapshot.phase)}<//>
        <${PhaseBadge}>KTC ${displayState(snapshot.turn_phase)}<//>
        <${PhaseBadge}>KDP ${displayState(snapshot.decision.stage)}<//>
        <${PhaseBadge}>KCL ${displayState(snapshot.runtime.state)}<//>
        ${transitions.length > 0 ? html`
          <${PhaseBadge}>observed ${transitions.length} transitions<//>
        ` : null}
      </div>

      ${phaseDiagnosis ? html`
        <${PhaseConditionsPanel} diagnosis=${phaseDiagnosis} />
      ` : null}

      <div class="grid gap-2 md:grid-cols-2 v2-monitoring-row">
        ${(Object.entries(INVARIANT_LABELS) as Array<[keyof KeeperCompositeInvariants, string]>).map(([key, label]) => {
          const ok = snapshot.invariants[key]
          return html`
            <div class=${`rounded-[var(--r-1)] border px-3 py-2 text-2xs leading-normal ${badgeTone(ok)} v2-monitoring-card`}>
              <div class="font-semibold">${label}</div>
              <div class="mt-1 font-mono">${ok ? 'ok' : 'violated'}</div>
            </div>
          `
        })}
      </div>

      ${transitions.length > 0 ? html`
        <div class="grid gap-2 v2-monitoring-row" role="log" aria-live="polite" aria-label="관측된 전이">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">관측된 전이</div>
          ${transitions.map(transition => html`
            <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-2xs leading-normal text-[var(--color-fg-primary)] v2-monitoring-row">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-mono text-[var(--color-fg-secondary)]">${toKeeperPhase(transition.prev_phase) ?? transition.prev_phase}</span>
                <span class="text-[var(--color-fg-disabled)]">→</span>
                <span class="font-mono text-[var(--color-accent-fg)]">${toKeeperPhase(transition.new_phase) ?? transition.new_phase}</span>
                <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs text-[var(--color-fg-muted)]">
                  ${transition.event_type ?? transitionType(transition.selected_event)}
                </span>
                <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs text-[var(--color-fg-muted)]">
                  ${transition.transition_outcome}
                </span>
              </div>
            </div>
          `)}
        </div>
      ` : null}
    </div>
  `
}
