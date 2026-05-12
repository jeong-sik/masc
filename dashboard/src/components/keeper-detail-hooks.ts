import { useState, useEffect } from 'preact/hooks'
import { fetchKeeperComposite, fetchKeeperRuntimeTrace } from '../api/keeper'
import type { KeeperCompositeSnapshot, KeeperRuntimeTraceResponse } from '../api/keeper'
import { setupVisibleAutoRefresh } from '../lib/auto-refresh'

const COMPOSITE_REFRESH_MS = 30_000
const RUNTIME_TRACE_REFRESH_MS = 30_000

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
export function useKeeperComposite(keeperName: string): KeeperCompositeSnapshot | null {
  const [snapshot, setSnapshot] = useState<KeeperCompositeSnapshot | null>(null)
  useEffect(() => {
    const controller = new AbortController()
    let cancelled = false
    const refresh = async () => {
      try {
        const result = await fetchKeeperComposite(keeperName, { signal: controller.signal })
        if (!cancelled && !controller.signal.aborted) setSnapshot(result)
      } catch {
        // best-effort polling — leave the previous snapshot in place
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
  return snapshot
}

export function useKeeperRuntimeTrace(keeperName: string): KeeperRuntimeTraceResponse | null {
  const [trace, setTrace] = useState<KeeperRuntimeTraceResponse | null>(null)
  useEffect(() => {
    const controller = new AbortController()
    let cancelled = false
    const refresh = async () => {
      try {
        const result = await fetchKeeperRuntimeTrace(keeperName, {
          limit: 200,
          signal: controller.signal,
        })
        if (!cancelled && !controller.signal.aborted) setTrace(result)
      } catch {
        // best-effort polling — leave the previous evidence in place
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
  return trace
}
