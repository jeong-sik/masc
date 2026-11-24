// Nav telemetry — client observer.
// Posts one event per surface/section transition to /api/v1/dashboard/nav-event.
// Aggregate counters only — no PII, no per-event storage on the server.

import { effect, type Signal } from '@preact/signals'
import { route } from '../router'
import type { RouteState } from '../types'
import { authSession, getActiveCsrfToken, getSingleUserToken } from '../core/auth'

export interface NavEvent {
  surface: string
  section: string | null
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
  const session = authSession.peek()
  // Never emit unauthenticated nav-event POSTs (prevents 401 console spam on boot/sign-out)
  if (session.kind !== 'single_user_local' && session.kind !== 'multi_account_signed_in') {
    return
  }
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (session.kind === 'multi_account_signed_in') {
    const csrf = getActiveCsrfToken()
    if (!csrf) return
    headers['x-masc-csrf-token'] = csrf
  } else {
    const token = getSingleUserToken()
    if (token) headers.Authorization = `Bearer ${token}`
  }
  void fetch(ENDPOINT, {
    method: 'POST',
    credentials: 'same-origin',
    headers,
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

    send({ surface, section })
  })

  return dispose
}
