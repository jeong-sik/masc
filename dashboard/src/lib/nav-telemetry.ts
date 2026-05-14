// Nav telemetry — RFC-0049 client observer.
// Posts one event per surface/section transition to /api/v1/dashboard/nav-event.
// Aggregate counters only — no PII, no per-event storage on the server.

import { effect, type Signal } from '@preact/signals'
import { route, REDIRECTED_FROM_PARAM } from '../router'
import type { RouteState } from '../types'

export interface NavEvent {
  surface: string
  section: string | null
  redirected_from: string | null
}

export interface NavTelemetryOptions {
  /** Override the route signal (test seam). */
  routeSignal?: Signal<RouteState>
  /** Override the POST sender (test seam). */
  send?: (event: NavEvent) => void
  /** Override the clock (test seam, ms). */
  now?: () => number
  /** Collapse identical (surface, section) re-emissions within this window. */
  collapseWindowMs?: number
}

export const DEFAULT_COLLAPSE_WINDOW_MS = 500

const ENDPOINT = '/api/v1/dashboard/nav-event'

function defaultSend(event: NavEvent): void {
  // keepalive lets the request survive page-unload without retry semantics.
  void fetch(ENDPOINT, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(event),
    keepalive: true,
  }).catch(() => { /* drop — telemetry is best-effort */ })
}

interface LastEmission {
  surface: string
  section: string | null
  at: number
}

/**
 * Subscribe to route changes and emit nav events.
 *
 * Returns the disposer so callers (and tests) can stop the subscription.
 */
export function startNavTelemetry(
  options: NavTelemetryOptions = {},
): () => void {
  const signal = options.routeSignal ?? route
  const send = options.send ?? defaultSend
  const now = options.now ?? Date.now
  const window = options.collapseWindowMs ?? DEFAULT_COLLAPSE_WINDOW_MS

  let last: LastEmission | null = null

  const dispose = effect(() => {
    const r = signal.value
    const surface = r.tab
    const section = r.params.section ?? null
    const rawRedirected = r.params[REDIRECTED_FROM_PARAM]
    const redirected_from = rawRedirected && rawRedirected.length > 0 ? rawRedirected : null
    const at = now()

    if (
      last !== null
      && last.surface === surface
      && last.section === section
      && at - last.at < window
    ) {
      return
    }
    last = { surface, section, at }

    send({ surface, section, redirected_from })
  })

  return dispose
}
