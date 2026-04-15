import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'

import {
  fetchKeeperStateDiagram,
  fetchKeeperTransitions,
  type KeeperTransition,
  type KeeperStateDiagramResponse,
} from '../api/keeper'
import { EmptyState } from './common/empty-state'
import { CytoscapeFsm } from './common/cytoscape-fsm'
import { MermaidGraph } from './common/mermaid-graph'
import { buildPhaseSpec, buildDecisionPipelineSpec, buildCascadeSpec } from './keeper-fsm-specs'
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

function normalizePhase(phase: string | null | undefined): string | null {
  if (!phase) return null
  return PHASE_ID_MAP[phase] ?? null
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

// Check if API returned structured data for Cytoscape rendering
function hasStructuredData(data: KeeperStateDiagramResponse): boolean {
  return typeof data.thompson_alpha === 'number'
    && Array.isArray(data.cascade_models)
}

export function KeeperStateDiagramPanel({ keeperName, currentPhase }: KeeperStateDiagramProps) {
  const [diagramData, setDiagramData] = useState<KeeperStateDiagramResponse | null>(null)
  const [transitions, setTransitions] = useState<KeeperTransition[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setError(null)

    Promise.allSettled([
      fetchKeeperStateDiagram(keeperName, { signal: controller.signal }),
      fetchKeeperTransitions(keeperName, 5, { signal: controller.signal }),
    ])
      .then(([diagramResult, transitionsResult]) => {
        if (controller.signal.aborted) return
        if (diagramResult.status === 'fulfilled') {
          setDiagramData(diagramResult.value)
        } else {
          setDiagramData(null)
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
        if (controller.signal.aborted) return
        setError(err instanceof Error ? err.message : 'state diagram fetch failed')
        setLoading(false)
      })

    return () => { controller.abort() }
  }, [keeperName])

  const livePhase = normalizePhase(currentPhase) ?? normalizePhase(diagramData?.current_phase)
  const registryPhase = normalizePhase(diagramData?.current_phase)
  const phaseMismatch = Boolean(livePhase && registryPhase && livePhase !== registryPhase)
  const useCytoscape = diagramData != null && hasStructuredData(diagramData)

  const phaseSpec = useMemo(
    () => buildPhaseSpec(livePhase),
    [livePhase],
  )

  const pipelineSpec = useMemo(
    () => {
      if (!diagramData || !useCytoscape) return null
      return buildDecisionPipelineSpec({
        phase: livePhase,
        thompsonAlpha: diagramData.thompson_alpha ?? 1,
        thompsonBeta: diagramData.thompson_beta ?? 1,
        toolCount: diagramData.tool_count ?? 0,
        recoveryFloorCount: diagramData.recovery_floor_count ?? 0,
      })
    },
    [diagramData, livePhase, useCytoscape],
  )

  const cascadeSpec = useMemo(
    () => {
      if (!diagramData || !useCytoscape) return null
      const models = diagramData.cascade_models
      if (!models || models.length === 0) return null
      return buildCascadeSpec({
        models,
        lastProviderResult: diagramData.last_provider_result ?? null,
      })
    },
    [diagramData, useCytoscape],
  )

  if (loading) {
    return html`
      <div class="flex items-center justify-center gap-2 py-6 text-[11px] text-[var(--text-dim)]">
        <span class="inline-block h-3 w-3 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin" aria-hidden="true"></span>
        상태 다이어그램 로딩중
      </div>
    `
  }

  if (error || !diagramData) {
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
        ${useCytoscape ? html`
          <span class="inline-flex items-center rounded-full border border-[rgba(99,102,241,0.3)] bg-[rgba(99,102,241,0.1)] px-2 py-0.5 text-[#818cf8]">
            interactive
          </span>
        ` : null}
      </div>

      ${phaseMismatch ? html`
        <div class="rounded-xl border border-[rgba(251,191,36,0.24)] bg-[rgba(251,191,36,0.08)] px-3 py-2 text-[11px] leading-[1.5] text-[var(--text-body)]">
          Live phase와 registry phase가 다릅니다. observed transition 기록을 참고하세요.
        </div>
      ` : null}

      <!-- Phase State Machine -->
      <div>
        <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] mb-2">Phase State Machine</div>
        ${useCytoscape ? html`
          <${CytoscapeFsm} spec=${phaseSpec} height="320px" />
        ` : html`
          <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
            <${MermaidGraph}
              source=${diagramData.mermaid}
              prefix="keeper-state-diagram"
              diagramClass="[&_svg]:max-w-full [&_svg]:mx-auto"
              minHeightClass="min-h-[120px]"
            />
          </div>
        `}
      </div>

      <!-- Decision Pipeline -->
      ${pipelineSpec ? html`
        <div class="mt-2">
          <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] mb-2">Decision Pipeline (Guard → Thompson → ToolPolicy)</div>
          <${CytoscapeFsm} spec=${pipelineSpec} height="240px" />
        </div>
      ` : diagramData.decision_pipeline_mermaid ? html`
        <div class="mt-2">
          <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] mb-2">Decision Pipeline (Guard → Thompson → ToolPolicy)</div>
          <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
            <${MermaidGraph}
              source=${diagramData.decision_pipeline_mermaid}
              prefix="decision-pipeline"
              diagramClass="[&_svg]:max-w-full [&_svg]:mx-auto"
              minHeightClass="min-h-[120px]"
            />
          </div>
        </div>
      ` : null}

      <!-- Cascade FSM -->
      ${cascadeSpec ? html`
        <div class="mt-2">
          <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] mb-2">Cascade FSM (Provider Failover)</div>
          <${CytoscapeFsm} spec=${cascadeSpec} height="280px" />
        </div>
      ` : diagramData.cascade_fsm_mermaid ? html`
        <div class="mt-2">
          <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] mb-2">Cascade FSM (Provider Failover)</div>
          <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
            <${MermaidGraph}
              source=${diagramData.cascade_fsm_mermaid}
              prefix="cascade-fsm"
              diagramClass="[&_svg]:max-w-full [&_svg]:mx-auto"
              minHeightClass="min-h-[120px]"
            />
          </div>
        </div>
      ` : null}

      <!-- Observed Transitions -->
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
