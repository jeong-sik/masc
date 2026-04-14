// Fleet data backing store — Phase 0 of dashboard consolidation.
//
// Centralizes the fetch logic for tool-quality and telemetry-summary, which
// Phase 2's fleet-health view will render side-by-side. Today each panel
// (tool-quality-panel, fleet-telemetry-panel, telemetry-unified) fetches
// independently; once multiple panels share a surface, independent fetches
// would race. This module provides a shared signal store + in-flight
// deduplication so the eventual merge does not re-invent the pattern.
//
// Design constraints:
//   - Existing panel export APIs (`refreshToolQuality`) remain unchanged.
//     Panels delegate their backing implementation here but keep their
//     public signature. See tool-quality-panel.ts for the delegation.
//   - This module is a pure data layer. No rendering, no route coupling.
//   - Requests are cancelled/deduplicated by requestId, matching the pattern
//     used by the existing panels (fleet-telemetry-panel.ts:247-309).

import { signal, type Signal } from '@preact/signals'
import {
  fetchTelemetrySummary,
  fetchToolQuality,
  type TelemetrySummaryResponse,
  type ToolQualityResponse,
} from '../api/dashboard'
import { isAbortError } from '../lib/async-state'

/**
 * Shared error formatter matching the previous tool-quality-panel behavior so
 * consumers can surface friendly timeout messages (e.g. "request timeout (35s)")
 * instead of the raw API helper string "GET /path: timeout after 35000ms".
 */
function formatFetchError(e: unknown): string {
  if (e instanceof Error && /timeout after \d+ms/i.test(e.message)) {
    const match = e.message.match(/timeout after (\d+)ms/i)
    const seconds = match?.[1] ? Math.round(Number(match[1]) / 1000) : '?'
    return `request timeout (${seconds}s)`
  }
  return e instanceof Error ? e.message : 'fetch failed'
}

// ---------- Shared tool quality ----------

export const sharedToolQuality: Signal<ToolQualityResponse | null> = signal(null)
export const sharedToolQualityLoading: Signal<boolean> = signal(false)
export const sharedToolQualityError: Signal<string | null> = signal(null)

let toolQualityRequestId = 0
let toolQualityController: AbortController | null = null

export interface RefreshSharedOptions {
  signal?: AbortSignal
  /** Override default n=5000 for tool-quality fetches. */
  n?: number
}

export async function refreshSharedToolQuality(opts: RefreshSharedOptions = {}): Promise<void> {
  const requestId = ++toolQualityRequestId
  toolQualityController?.abort()
  const controller = new AbortController()
  toolQualityController = controller

  const upstream = opts.signal
  const abortFromUpstream = () => controller.abort()
  if (upstream) {
    if (upstream.aborted) controller.abort()
    else upstream.addEventListener('abort', abortFromUpstream, { once: true })
  }

  sharedToolQualityLoading.value = true
  sharedToolQualityError.value = null

  try {
    const json = await fetchToolQuality({ n: opts.n ?? 5000, signal: controller.signal })
    if (requestId !== toolQualityRequestId) return
    sharedToolQuality.value = json
  } catch (e) {
    if (requestId !== toolQualityRequestId) return
    if (isAbortError(e)) return
    sharedToolQualityError.value = formatFetchError(e)
  } finally {
    upstream?.removeEventListener('abort', abortFromUpstream)
    if (toolQualityController === controller) toolQualityController = null
    if (requestId === toolQualityRequestId) sharedToolQualityLoading.value = false
  }
}

/**
 * Cancel the in-flight tool quality request, if any. Used by panel lifecycle
 * cleanup to avoid completing a fetch after unmount.
 */
export function cancelSharedToolQuality(): void {
  toolQualityRequestId += 1
  toolQualityController?.abort()
  toolQualityController = null
  sharedToolQualityLoading.value = false
}

// ---------- Shared telemetry summary ----------

export const sharedTelemetrySummary: Signal<TelemetrySummaryResponse | null> = signal(null)
export const sharedTelemetrySummaryLoading: Signal<boolean> = signal(false)
export const sharedTelemetrySummaryError: Signal<string | null> = signal(null)

let summaryRequestId = 0
let summaryController: AbortController | null = null

export async function refreshSharedTelemetrySummary(opts: { signal?: AbortSignal } = {}): Promise<void> {
  const requestId = ++summaryRequestId
  summaryController?.abort()
  const controller = new AbortController()
  summaryController = controller

  const upstream = opts.signal
  const abortFromUpstream = () => controller.abort()
  if (upstream) {
    if (upstream.aborted) controller.abort()
    else upstream.addEventListener('abort', abortFromUpstream, { once: true })
  }

  sharedTelemetrySummaryLoading.value = true
  sharedTelemetrySummaryError.value = null

  try {
    const json = await fetchTelemetrySummary({ signal: controller.signal })
    if (requestId !== summaryRequestId) return
    sharedTelemetrySummary.value = json
  } catch (e) {
    if (requestId !== summaryRequestId) return
    if (isAbortError(e)) return
    sharedTelemetrySummaryError.value = formatFetchError(e)
  } finally {
    upstream?.removeEventListener('abort', abortFromUpstream)
    if (summaryController === controller) summaryController = null
    if (requestId === summaryRequestId) sharedTelemetrySummaryLoading.value = false
  }
}

export function cancelSharedTelemetrySummary(): void {
  summaryRequestId += 1
  summaryController?.abort()
  summaryController = null
  sharedTelemetrySummaryLoading.value = false
}

// ---------- Test-only reset ----------

/** Reset all shared signals + controllers. Exposed for unit tests only. */
export function __resetFleetDataCoreForTests(): void {
  cancelSharedToolQuality()
  cancelSharedTelemetrySummary()
  sharedToolQuality.value = null
  sharedToolQualityError.value = null
  sharedTelemetrySummary.value = null
  sharedTelemetrySummaryError.value = null
}
