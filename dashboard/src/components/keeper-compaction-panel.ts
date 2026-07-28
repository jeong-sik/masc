import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'

import {
  fetchKeeperComposite,
  type KeeperCompositeSnapshot,
} from '../api/keeper'
import { EmptyState } from './common/feedback-state'
import { InlineSpinner } from './common/inline-spinner'
import { CytoscapeFsm } from './common/cytoscape-fsm'
import { StatusChip } from './common/status-chip'
import { buildCompactionSpec } from './keeper-fsm-specs'
import { DEFAULT_PANEL_REFRESH_MS, setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { toKeeperPhase } from '../keeper-store-normalize'

interface KeeperCompactionPanelProps {
  keeperName: string
  /** RFC-0046: parent-supplied composite snapshot. When provided,
   *  this panel reads the SSOT from the shared FsmHub fetch instead
   *  of issuing its own /composite call. */
  snapshot?: KeeperCompositeSnapshot | null
}

/**
 * Compaction sub-FSM view (KMC phase/stage badges + Cytoscape diagram).
 *
 * Runtime-truth: `/composite` is authoritative for the current KSM/KMC
 * lifecycle state.
 */
export function KeeperCompactionPanel({
  keeperName,
  snapshot: externalSnapshot,
}: KeeperCompactionPanelProps) {
  const [internalSnapshot, setInternalSnapshot] = useState<KeeperCompositeSnapshot | null>(null)
  const snapshot = externalSnapshot ?? internalSnapshot
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setError(null)

    const refresh = async () => {
      // RFC-0046 §7 #1: skip composite fetch when parent supplies it.
      // `undefined` = standalone caller (legacy fallback); `null` =
      // parent is still loading, wait rather than dual-fetch.
      if (externalSnapshot !== undefined) {
        setLoading(false)
        return
      }
      try {
        const result = await fetchKeeperComposite(keeperName, { signal: controller.signal })
        if (controller.signal.aborted) return
        setInternalSnapshot(result)
        setError(null)
      } catch (err) {
        if (controller.signal.aborted) return
        setInternalSnapshot(null)
        setError(err instanceof Error ? err.message : 'composite fetch failed')
      } finally {
        if (!controller.signal.aborted) setLoading(false)
      }
    }

    refresh()
    const cleanup = setupVisibleAutoRefresh(() => refresh(), DEFAULT_PANEL_REFRESH_MS)

    return () => {
      controller.abort()
      cleanup()
    }
    // `externalSnapshot` is intentionally excluded from the dependency list
    // (RFC-0046 §7 #1): standalone mode (`undefined`) never changes at
    // runtime, and parent-supplied mode must not re-run this effect on every
    // parent poll tick — rendering already reads `externalSnapshot` directly
    // via the `snapshot` binding below.
  }, [keeperName])

  if (loading) {
    return html`
      <div class="flex items-center justify-center gap-2 py-6 text-2xs text-[var(--color-fg-disabled)]" role="status">
        <${InlineSpinner} />
        컴팩션 상태 로딩중
      </div>
    `
  }

  if (error || !snapshot) {
    return html`<${EmptyState} message=${error ?? '컴팩션 상태 데이터 없음'} compact />`
  }

  const phase = snapshot.phase ?? null
  // RFC-0135 PR-2 normalization (audit A2): the composite observer
  // emits lowercase phase tokens while flat keeper records use
  // PascalCase. `toKeeperPhase` collapses both into the canonical
  // PascalCase form so a single equality covers either wire shape.
  const isCompacting = toKeeperPhase(phase) === 'Compacting'
  const compactionStage = snapshot.compaction.stage ?? (isCompacting ? 'compacting' : 'accumulating')
  const compactionSpec = buildCompactionSpec(compactionStage, phase)

  return html`
    <div class="flex flex-col gap-3 v2-monitoring-panel">
      <div class="flex flex-wrap items-center gap-2 text-3xs text-[var(--color-fg-disabled)] v2-monitoring-toolbar">
        <${StatusChip} tone="neutral" uppercase=${false}>KMC ${compactionStage}</${StatusChip}>
        ${isCompacting ? html`
          <${StatusChip} tone="warn" uppercase=${false}>compacting</${StatusChip}>
        ` : null}
      </div>

      <div class="mt-2">
        <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)] mb-2">
          Compaction sub-FSM (KeeperCompactionLifecycle.tla)
        </div>
        <${CytoscapeFsm} spec=${compactionSpec} height="200px" />
      </div>
    </div>
  `
}
