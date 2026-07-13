import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'

import {
  fetchKeeperComposite,
  fetchKeeperStateDiagram,
  fetchKeeperTransitions,
  type KeeperCompositeSnapshot,
  type KeeperStateDiagramResponse,
  type KeeperTransition,
} from '../api/keeper'
import { isRecord } from './common/normalize'
import { EmptyState } from './common/feedback-state'
import { InlineSpinner } from './common/inline-spinner'
import { CytoscapeFsm } from './common/cytoscape-fsm'
import { MermaidGraph } from './common/mermaid-graph'
import { FilterChips } from './common/filter-chips'
import { buildCompositeFsmSpec } from './keeper-fsm-specs'
import { TurnFsmDetailPanel } from './turn-fsm-detail-panel'
import { displayState, INVARIANT_LABELS } from './fsm-hub-types'
import type { KeeperCompositeInvariants } from '../api/schemas/keeper-composite'
import {
  normalizePhaseDiagnosis,
  PhaseConditionsPanel,
} from './phase-conditions-panel'
// RFC-0135 PR-2: phase casing SSOT — `toKeeperPhase` is the single
// source. The local PHASE_ID_MAP (previously lines 42-69 of this file)
// duplicated BACKEND_PHASE_MAP in keeper-store-normalize and drifted
// independently; that map and the local `normalizePhase` export are
// removed in favor of the canonical helper.
import { toKeeperPhase } from '../keeper-store-normalize'

interface KeeperStateDiagramProps {
  keeperName: string
  /** RFC-0046: parent-supplied composite snapshot. When provided,
   *  this panel reads the SSOT from the shared FsmHub fetch instead
   *  of issuing its own /composite call. */
  snapshot?: KeeperCompositeSnapshot | null
}

function PhaseBadge({ accent, children }: { accent?: boolean; children: unknown }) {
  const cls = accent
    ? 'inline-flex items-center rounded-[var(--r-0)] border border-[var(--accent-30)] bg-[var(--accent-10)] px-2 py-0.5 text-[var(--color-accent-fg)]'
    : 'inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5'
  return html`<span class="${cls}">${children}</span>`
}

// INVARIANT_LABELS is the SSOT in `fsm-hub-types.ts:124` — same five TLA
// joint observer invariants emitted by `keeper_composite_observer.ml`. A
// prior local copy in this file enumerated only four (dropped
// `phase_derivation_agreement`), so the operator panel below silently
// hid one of the five invariant rows — they would never see KSM phase
// derivation drift (stored phase vs `derive_phase(conditions)` result,
// the strictest TLA agreement check).

type DiagramView = 'cytoscape' | 'mermaid'

const DIAGRAM_VIEW_CHIPS: Array<{ key: DiagramView; label: string; title: string }> = [
  { key: 'cytoscape', label: 'Cytoscape', title: 'Composite lifecycle graph' },
  { key: 'mermaid', label: 'Mermaid', title: 'Backend-generated phase diagram' },
]

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
  const [stateDiagram, setStateDiagram] = useState<KeeperStateDiagramResponse | null>(null)
  const [transitions, setTransitions] = useState<KeeperTransition[]>([])
  const [error, setError] = useState<string | null>(null)
  const [diagramError, setDiagramError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [diagramView, setDiagramView] = useState<DiagramView>('cytoscape')

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setError(null)
    setDiagramError(null)
    setStateDiagram(null)

    // RFC-0046 §7 #1: skip composite fetch when parent supplies it.
    // Caller-passed `undefined` means standalone mode (legacy); `null`
    // means parent is loading — wait rather than dual-fetch.
    const compositePromise: Promise<KeeperCompositeSnapshot | null> = externalSnapshot !== undefined
      ? Promise.resolve(externalSnapshot)
      : fetchKeeperComposite(keeperName, { signal: controller.signal })

    Promise.allSettled([
      compositePromise,
      fetchKeeperStateDiagram(keeperName, { signal: controller.signal }),
      fetchKeeperTransitions(keeperName, 5, { signal: controller.signal }),
    ])
      .then(([snapshotResult, stateDiagramResult, transitionsResult]) => {
        if (controller.signal.aborted) return

        if (snapshotResult.status === 'fulfilled') {
          setInternalSnapshot(snapshotResult.value)
        } else {
          setInternalSnapshot(null)
          setError(snapshotResult.reason instanceof Error ? snapshotResult.reason.message : 'composite fetch failed')
        }

        if (stateDiagramResult.status === 'fulfilled') {
          setStateDiagram(stateDiagramResult.value)
        } else {
          setStateDiagram(null)
          setDiagramError(
            stateDiagramResult.reason instanceof Error
              ? stateDiagramResult.reason.message
              : 'state-diagram fetch failed',
          )
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

  // RFC-0046 Step 5: keeper.phase (flat field) is no longer surfaced here.
  // Composite snapshot is the single source of truth; backend two-store
  // drift detection moves to the FsmHub invariant area (future RFC).
  const phaseDiagnosis = useMemo(
    () => snapshot ? normalizePhaseDiagnosis(snapshotPhaseDiagnosis(snapshot)) : null,
    [snapshot],
  )
  const mermaidSource = stateDiagram?.mermaid?.trim() ?? ''

  const compositeSpec = useMemo(
    () => snapshot
      ? buildCompositeFsmSpec({
          phase: snapshot.phase,
          turnPhase: snapshot.turn_phase,
          decisionStage: snapshot.decision.stage,
          runtimeState: snapshot.runtime.state,
          compactionStage: snapshot.compaction.stage,
        })
      : null,
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

  if (error || !snapshot || !compositeSpec) {
    return html`<${EmptyState} message=${error ?? 'composite lifecycle 없음'} compact />`
  }

  return html`
    <div class="flex flex-col gap-3 v2-monitoring-panel">
      <div class="flex flex-wrap items-center gap-2 text-3xs text-[var(--color-fg-disabled)] v2-monitoring-toolbar">
        <${PhaseBadge} accent>composite ${displayState(snapshot.phase)}<//>
        <${PhaseBadge}>KTC ${displayState(snapshot.turn_phase)}<//>
        <${PhaseBadge}>KDP ${displayState(snapshot.decision.stage)}<//>
        <${PhaseBadge}>KCL ${displayState(snapshot.runtime.state)}<//>
        <${PhaseBadge}>KMC ${displayState(snapshot.compaction.stage)}<//>
        ${transitions.length > 0 ? html`
          <${PhaseBadge}>observed ${transitions.length} transitions<//>
        ` : null}
      </div>

      <div>
        <div class="mb-2 flex flex-wrap items-center justify-between gap-2 v2-monitoring-toolbar">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
            통합 라이프사이클 (KSM · KTC · KDP · KCL · KMC)
          </div>
          <${FilterChips}
            chips=${DIAGRAM_VIEW_CHIPS}
            value=${diagramView}
            onChange=${setDiagramView}
            tone="accent"
          />
        </div>
        ${diagramView === 'cytoscape' ? html`
          <div role="tabpanel" aria-label="Composite lifecycle Cytoscape graph">
            <${CytoscapeFsm} spec=${compositeSpec} height="320px" />
          </div>
        ` : html`
          <div role="tabpanel" aria-label="Backend-generated Mermaid phase diagram">
            ${diagramError ? html`
              <${EmptyState} message=${diagramError} compact />
            ` : mermaidSource ? html`
              <div class="grid gap-2">
                <${MermaidGraph}
                  source=${mermaidSource}
                  prefix=${`keeper-phase-${keeperName}`}
                  minHeightClass="min-h-72"
                  fallbackText=${mermaidSource}
                />
                <div class="flex flex-wrap items-center gap-1.5 text-3xs text-[var(--color-fg-disabled)]">
                  <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5">
                    backend phase ${stateDiagram?.current_phase ?? 'unknown'}
                  </span>
                  <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5">
                    response.mermaid
                  </span>
                </div>
              </div>
            ` : html`
              <${EmptyState} message="backend Mermaid diagram 없음" compact />
            `}
          </div>
        `}
      </div>

      <${TurnFsmDetailPanel} snapshot=${snapshot} />

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
