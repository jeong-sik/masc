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
import { EmptyState } from './common/empty-state'
import { InlineSpinner } from './common/inline-spinner'
import { CytoscapeFsm } from './common/cytoscape-fsm'
import { MermaidGraph } from './common/mermaid-graph'
import { FilterChips } from './common/filter-chips'
import { buildCompositeFsmSpec } from './keeper-fsm-specs'
import { TurnFsmDetailPanel } from './turn-fsm-detail-panel'
import { displayState } from './fsm-hub-types'
import {
  normalizePhaseDiagnosis,
  PhaseConditionsPanel,
} from './phase-conditions-panel'

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
  Zombie: 'Zombie',
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
  zombie: 'Zombie',
}

const INVARIANT_LABELS: Array<[keyof KeeperCompositeSnapshot['invariants'], string]> = [
  ['phase_turn_alignment', '단계 ⇔ 턴'],
  ['no_cascade_before_measurement', 'Cascade 순서'],
  ['compaction_atomicity', '압축 원자성'],
  ['event_priority_monotone', '이벤트 우선순위'],
]

type DiagramView = 'cytoscape' | 'mermaid'

const DIAGRAM_VIEW_CHIPS: Array<{ key: DiagramView; label: string; title: string }> = [
  { key: 'cytoscape', label: 'Cytoscape', title: 'Composite lifecycle graph' },
  { key: 'mermaid', label: 'Mermaid', title: 'Backend-generated phase diagram' },
]

export function normalizePhase(phase: string | null | undefined): string | null {
  if (!phase) return null
  return PHASE_ID_MAP[phase] ?? phase
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

export function signalTone(severity: string | null | undefined): string {
  // Unknown severity → treat as warn (fail-closed). Only an explicit "ok" from
  // the backend renders as green. See issue #9894 (Unknown → Permissive Default
  // anti-pattern; CLAUDE.md #2). Backend emits 'ok' | 'warn' | 'bad' today via
  // lib/keeper/keeper_transition_audit.ml; any new severity must be mapped
  // here explicitly before it is allowed to show as healthy.
  switch (severity) {
    case 'bad':
      return 'border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--color-status-err)]'
    case 'warn':
      return 'border-[var(--warn-24)] bg-[var(--warn-8)] text-[var(--color-status-warn)]'
    case 'ok':
      return 'border-[var(--ok-border)] bg-[var(--ok-soft)] text-[var(--color-status-ok)]'
    default:
      // Client-side observability: record unexpected severities so future
      // backend additions are noticed before they regress to silent-OK.
      if (typeof console !== 'undefined' && severity != null && severity !== '') {
        console.warn('[signalTone] unknown severity; rendering as warn', { severity })
      }
      return 'border-[var(--warn-24)] bg-[var(--warn-8)] text-[var(--color-status-warn)]'
  }
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
          cascadeState: snapshot.cascade.state,
          compactionStage: snapshot.compaction.stage,
        })
      : null,
    [snapshot],
  )

  if (loading) {
    return html`
      <div class="flex items-center justify-center gap-2 py-6 text-2xs text-[var(--color-fg-disabled)]" role="status">
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
      <div class="flex flex-wrap items-center gap-2 text-3xs text-[var(--color-fg-disabled)]">
        <${PhaseBadge} accent>composite ${displayState(snapshot.phase)}<//>
        <${PhaseBadge}>KTC ${displayState(snapshot.turn_phase)}<//>
        <${PhaseBadge}>KDP ${displayState(snapshot.decision.stage)}<//>
        <${PhaseBadge}>KCL ${displayState(snapshot.cascade.state)}<//>
        <${PhaseBadge}>KMC ${displayState(snapshot.compaction.stage)}<//>
        ${transitions.length > 0 ? html`
          <${PhaseBadge}>observed ${transitions.length} transitions<//>
        ` : null}
      </div>

      <div>
        <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
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

      <div class="grid gap-2 md:grid-cols-2">
        ${INVARIANT_LABELS.map(([key, label]) => {
          const ok = snapshot.invariants[key]
          return html`
            <div class=${`rounded-[var(--r-1)] border px-3 py-2 text-2xs leading-normal ${badgeTone(ok)}`}>
              <div class="font-semibold">${label}</div>
              <div class="mt-1 font-mono">${ok ? 'ok' : 'violated'}</div>
            </div>
          `
        })}
      </div>

      ${transitions.length > 0 ? html`
        <div class="grid gap-2" role="log" aria-live="polite" aria-label="관측된 전이">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">관측된 전이</div>
          ${transitions.map(transition => html`
            <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-2xs leading-normal text-[var(--color-fg-primary)]">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-mono text-[var(--color-fg-secondary)]">${normalizePhase(transition.prev_phase) ?? transition.prev_phase}</span>
                <span class="text-[var(--color-fg-disabled)]">→</span>
                <span class="font-mono text-[var(--color-accent-fg)]">${normalizePhase(transition.new_phase) ?? transition.new_phase}</span>
                <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs text-[var(--color-fg-muted)]">
                  ${transition.event_type ?? transitionType(transition.selected_event)}
                </span>
                ${transition.operator_signal ? html`
                  <span class=${`rounded-[var(--r-0)] border px-2 py-0.5 text-3xs ${signalTone(transition.operator_signal.severity)}`}>
                    ${transition.operator_signal.requires_operator_decision ? 'decision required' : transition.operator_signal.class}
                  </span>
                ` : null}
              </div>
              ${transition.operator_signal ? html`
                <div class="mt-1 text-[var(--color-fg-muted)]">
                  ${transition.operator_signal.summary}
                  ${transition.operator_signal.next_human_action
                    ? html`<span class="text-[var(--color-status-warn)]"> · ${transition.operator_signal.next_human_action}</span>`
                    : null}
                </div>
              ` : null}
            </div>
          `)}
        </div>
      ` : null}
    </div>
  `
}
