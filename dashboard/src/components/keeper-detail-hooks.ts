import { useState, useEffect } from 'preact/hooks'
import { keeperRuntimeTraceRefreshNonce } from './keeper-runtime-trace-refresh'
import { fetchKeeperComposite, fetchKeeperRuntimeTrace } from '../api/keeper'
import type { KeeperCompositeSnapshot, KeeperRuntimeTraceResponse } from '../api/keeper'
import { setupObservationRefresh } from '../lib/observation-refresh'
import { errorMessageOr } from '../lib/format-string'
import {
  applyFetchFailed,
  applyFetchSucceeded,
  loadingEvidence,
  type EvidenceState,
} from './keeper-detail-evidence-state'

/**
 * Typed evidence state shared by the keeper detail surface. The union
 * (`loading | fresh | stale | error`) closes the Unknown→Permissive
 * Default workaround: a 404 on /composite no longer leaves rendered
 * cards backed by the last successful payload. See
 * [keeper-detail-evidence-state.ts] for the rationale.
 */
export type KeeperDetailEvidenceState<T> = EvidenceState<T>

/**
 * RFC-0046 §7 follow-up #1: single composite snapshot fetch shared
 * across the detail surface. Before this hook KeeperStateDiagramPanel
 * each issued their own /composite call;
 * now keeper-detail owns the fetch and threads the snapshot down via
 * the snapshot prop introduced in PR #14226.
 *
 * FsmHub owns its own reducer. This hook serves the two derived panels.
 */
export function useKeeperCompositeEvidence(keeperName: string): KeeperDetailEvidenceState<KeeperCompositeSnapshot> {
  const [evidence, setEvidence] = useState<KeeperDetailEvidenceState<KeeperCompositeSnapshot>>(loadingEvidence)
  useEffect(() => {
    let cancelled = false
    const refresh = async (signal: AbortSignal) => {
      try {
        const result = await fetchKeeperComposite(keeperName, { signal: signal })
        if (!cancelled && !signal.aborted) {
          setEvidence(applyFetchSucceeded(result, Date.now()))
        }
      } catch (err) {
        if (!cancelled && !signal.aborted) {
          const message = errorMessageOr(err, 'composite fetch failed')
          setEvidence((current) => applyFetchFailed(current, message, Date.now()))
          throw err
        }
      }
    }
    const cleanup = setupObservationRefresh(refresh, { topics: ['keeper_composite'], keeperName,
      resetRead: () => { setEvidence(loadingEvidence) } })
    return () => {
      cancelled = true
      cleanup()
    }
  }, [keeperName])
  return evidence
}

export function useKeeperRuntimeTraceEvidence(keeperName: string): KeeperDetailEvidenceState<KeeperRuntimeTraceResponse> {
  const [evidence, setEvidence] = useState<KeeperDetailEvidenceState<KeeperRuntimeTraceResponse>>(loadingEvidence)
  // Read the refresh nonce during render so the component subscribes to it;
  // a config save bumps it, re-running the effect below to re-fetch the trace.
  const refreshNonce = keeperRuntimeTraceRefreshNonce.value
  useEffect(() => {
    let cancelled = false
    const refresh = async (signal: AbortSignal) => {
      try {
        const result = await fetchKeeperRuntimeTrace(keeperName, {
          limit: 200,
          signal: signal,
        })
        if (!cancelled && !signal.aborted) {
          setEvidence(applyFetchSucceeded(result, Date.now()))
        }
      } catch (err) {
        if (!cancelled && !signal.aborted) {
          const message = errorMessageOr(err, 'runtime trace fetch failed')
          setEvidence((current) => applyFetchFailed(current, message, Date.now()))
          throw err
        }
      }
    }
    const cleanup = setupObservationRefresh(refresh, { topics: ['keeper_runtime_trace'], keeperName,
      resetRead: () => { setEvidence(loadingEvidence) } })
    return () => {
      cancelled = true
      cleanup()
    }
  }, [keeperName, refreshNonce])
  return evidence
}
