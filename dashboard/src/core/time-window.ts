/**
 * Shared Time Window (`?win=24h|7d|30d`) & Synchronized Chart Crosshair Bus (`uPlot.sync('masc-telemetry')`).
 */

import { signal, type ReadonlySignal } from '@preact/signals'

export type TimeWindow = '24h' | '7d' | '30d'

export const TIME_WINDOW_PARAM = 'win'
export const TIME_WINDOWS: readonly TimeWindow[] = ['24h', '7d', '30d']
export const CROSSHAIR_SYNC_KEY = 'masc-telemetry'

export function parseTimeWindow(raw: string | null | undefined): TimeWindow {
  if (raw === '7d' || raw === '30d' || raw === '24h') return raw
  return '24h'
}

export function readTimeWindowFromUrl(): TimeWindow {
  if (typeof window === 'undefined') return '24h'
  const params = new URLSearchParams(window.location.search)
  return parseTimeWindow(params.get(TIME_WINDOW_PARAM))
}

const timeWindowSignal = signal<TimeWindow>(readTimeWindowFromUrl())
export const timeWindow: ReadonlySignal<TimeWindow> = timeWindowSignal

export function setTimeWindow(next: TimeWindow): void {
  if (timeWindowSignal.peek() === next) return
  timeWindowSignal.value = next
  if (typeof window !== 'undefined' && typeof window.history?.replaceState === 'function') {
    const url = new URL(window.location.href)
    url.searchParams.set(TIME_WINDOW_PARAM, next)
    window.history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`)
  }
}

export function timeWindowSeconds(win: TimeWindow): number {
  switch (win) {
    case '24h': return 86_400
    case '7d': return 7 * 86_400
    case '30d': return 30 * 86_400
  }
}

/**
 * Maps the global TimeWindow to the closed set `{1, 7, 14}` accepted by
 * `GET /api/v1/dashboard/provider-usage-history?days=...`.
 */
export function timeWindowProviderDays(win: TimeWindow): 1 | 7 | 14 {
  switch (win) {
    case '24h': return 1
    case '7d': return 7
    case '30d': return 14
  }
}

// ── Shared Crosshair Bus ────────────────────────────────────────────────

export interface CrosshairCursor {
  readonly timestamp: number | null
  readonly sourceId: string | null
}

const crosshairSignal = signal<CrosshairCursor>({ timestamp: null, sourceId: null })
export const crosshairCursor: ReadonlySignal<CrosshairCursor> = crosshairSignal

export function publishCrosshair(timestamp: number | null, sourceId: string | null): void {
  const cur = crosshairSignal.peek()
  if (cur.timestamp === timestamp && cur.sourceId === sourceId) return
  crosshairSignal.value = { timestamp, sourceId }
}

interface UPlotSyncFactory {
  sync(key: string): unknown
}

let cachedSyncPubSub: unknown = null

export function getUPlotSync(uPlotLib: UPlotSyncFactory): unknown {
  if (!cachedSyncPubSub) {
    cachedSyncPubSub = uPlotLib.sync(CROSSHAIR_SYNC_KEY)
  }
  return cachedSyncPubSub
}

export function resetTimeWindowForTests(initial: TimeWindow = '24h'): void {
  timeWindowSignal.value = initial
  crosshairSignal.value = { timestamp: null, sourceId: null }
  cachedSyncPubSub = null
}
