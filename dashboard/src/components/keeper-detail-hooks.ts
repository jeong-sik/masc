import { useState, useEffect } from 'preact/hooks'
import { fetchKeeperComposite, fetchKeeperRuntimeTrace } from '../api/keeper'
import type { KeeperCompositeSnapshot, KeeperRuntimeTraceResponse } from '../api/keeper'
import { setupVisibleAutoRefresh } from '../lib/auto-refresh'

const COMPOSITE_REFRESH_MS = 30_000
const RUNTIME_TRACE_REFRESH_MS = 30_000

export interface KeeperDetailEvidenceState<T> {
  data: T | null
  refreshedAtMs: number | null
  error: string | null
  loading: boolean
}

const emptyEvidence = <T,>(): KeeperDetailEvidenceState<T> => ({
  data: null,
  refreshedAtMs: null,
  error: null,
  loading: true,
})

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
  const [evidence, setEvidence] = useState<KeeperDetailEvidenceState<KeeperCompositeSnapshot>>(() => emptyEvidence())
  useEffect(() => {
    const controller = new AbortController()
    let cancelled = false
    setEvidence(emptyEvidence())
    const refresh = async () => {
      try {
        const result = await fetchKeeperComposite(keeperName, { signal: controller.signal })
        if (!cancelled && !controller.signal.aborted) {
          setEvidence({
            data: result,
            refreshedAtMs: Date.now(),
            error: null,
            loading: false,
          })
        }
      } catch (err) {
        if (!cancelled && !controller.signal.aborted) {
          setEvidence((current) => ({
            ...current,
            error: errorMessage(err, 'composite fetch failed'),
            loading: false,
          }))
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
  return useKeeperCompositeEvidence(keeperName).data
}

export function useKeeperRuntimeTraceEvidence(keeperName: string): KeeperDetailEvidenceState<KeeperRuntimeTraceResponse> {
  const [evidence, setEvidence] = useState<KeeperDetailEvidenceState<KeeperRuntimeTraceResponse>>(() => emptyEvidence())
  useEffect(() => {
    const controller = new AbortController()
    let cancelled = false
    setEvidence(emptyEvidence())
    const refresh = async () => {
      try {
        const result = await fetchKeeperRuntimeTrace(keeperName, {
          limit: 200,
          signal: controller.signal,
        })
        if (!cancelled && !controller.signal.aborted) {
          setEvidence({
            data: result,
            refreshedAtMs: Date.now(),
            error: null,
            loading: false,
          })
        }
      } catch (err) {
        if (!cancelled && !controller.signal.aborted) {
          setEvidence((current) => ({
            ...current,
            error: errorMessage(err, 'runtime trace fetch failed'),
            loading: false,
          }))
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
  return useKeeperRuntimeTraceEvidence(keeperName).data
}
