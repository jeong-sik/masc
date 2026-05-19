import { useState, useEffect } from 'preact/hooks'
import { fetchKeeperComposite, fetchKeeperRuntimeTrace } from '../api/keeper'
import type { KeeperCompositeSnapshot, KeeperRuntimeTraceResponse } from '../api/keeper'
import { setupVisibleAutoRefresh } from '../lib/auto-refresh'
import {
  applyFetchFailed,
  applyFetchSucceeded,
  evidenceFreshData,
  loadingEvidence,
  type EvidenceState,
} from './keeper-detail-evidence-state'

const COMPOSITE_REFRESH_MS = 30_000
const RUNTIME_TRACE_REFRESH_MS = 30_000

/**
 * Typed evidence state shared by the keeper detail surface. The union
 * (`loading | fresh | stale | error`) closes the Unknown→Permissive
 * Default workaround: a 404 on /composite no longer leaves rendered
 * cards backed by the last successful payload. See
 * [keeper-detail-evidence-state.ts] for the rationale.
 */
export type KeeperDetailEvidenceState<T> = EvidenceState<T>

function errorMessage(err: unknown, fallback: string): string {
  return err instanceof Error ? err.message : fallback
}

/**
 * RFC-0046 §7 follow-up #1: single composite snapshot fetch shared
 * across the detail surface. Before this hook KeeperStateDiagramPanel
 * and KeeperMemoryTierPanel each issued their own /composite call;
 * now keeper-detail owns the fetch and threads the snapshot down via
 * the snapshot prop introduced in PR #14226.
 *
 * FsmHub still has its own polling/reducer loop — see RFC §7 for the
 * remaining dedup work. This hook handles only the two derived panels.
 */
export function useKeeperCompositeEvidence(keeperName: string): KeeperDetailEvidenceState<KeeperCompositeSnapshot> {
  const [evidence, setEvidence] = useState<KeeperDetailEvidenceState<KeeperCompositeSnapshot>>(loadingEvidence)
  useEffect(() => {
    const controller = new AbortController()
    let cancelled = false
    setEvidence(loadingEvidence)
    const refresh = async () => {
      try {
        const result = await fetchKeeperComposite(keeperName, { signal: controller.signal })
        if (!cancelled && !controller.signal.aborted) {
          setEvidence(applyFetchSucceeded(result, Date.now()))
        }
      } catch (err) {
        if (!cancelled && !controller.signal.aborted) {
          const message = errorMessage(err, 'composite fetch failed')
          setEvidence((current) => applyFetchFailed(current, message, Date.now()))
        }
      }
    }
    void refresh()
    const cleanup = setupVisibleAutoRefresh(refresh, COMPOSITE_REFRESH_MS)
    return () => {
      cancelled = true
      controller.abort()
      cleanup()
    }
  }, [keeperName])
  return evidence
}

export function useKeeperComposite(keeperName: string): KeeperCompositeSnapshot | null {
  return evidenceFreshData(useKeeperCompositeEvidence(keeperName))
}

export function useKeeperRuntimeTraceEvidence(keeperName: string): KeeperDetailEvidenceState<KeeperRuntimeTraceResponse> {
  const [evidence, setEvidence] = useState<KeeperDetailEvidenceState<KeeperRuntimeTraceResponse>>(loadingEvidence)
  useEffect(() => {
    const controller = new AbortController()
    let cancelled = false
    setEvidence(loadingEvidence)
    const refresh = async () => {
      try {
        const result = await fetchKeeperRuntimeTrace(keeperName, {
          limit: 200,
          signal: controller.signal,
        })
        if (!cancelled && !controller.signal.aborted) {
          setEvidence(applyFetchSucceeded(result, Date.now()))
        }
      } catch (err) {
        if (!cancelled && !controller.signal.aborted) {
          const message = errorMessage(err, 'runtime trace fetch failed')
          setEvidence((current) => applyFetchFailed(current, message, Date.now()))
        }
      }
    }
    void refresh()
    const cleanup = setupVisibleAutoRefresh(refresh, RUNTIME_TRACE_REFRESH_MS)
    return () => {
      cancelled = true
      controller.abort()
      cleanup()
    }
  }, [keeperName])
  return evidence
}

export function useKeeperRuntimeTrace(keeperName: string): KeeperRuntimeTraceResponse | null {
  return evidenceFreshData(useKeeperRuntimeTraceEvidence(keeperName))
}
