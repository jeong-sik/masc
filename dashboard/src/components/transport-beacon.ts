// Transport beacon — operator-facing signal for the dashboard SSE stream.
//
// Renders a single chip for the browser's client channel only. Server-wide
// transport truth lives in the hidden Diagnostics transport surface backed by
// /api/v1/dashboard/transport-health.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import {
  dashboardObserverConnected,
  dashboardObserverEventCount60s,
  dashboardObserverLastEventAt,
  dashboardObserverLastActivityAt,
  dashboardObserverIdleTimeoutMs,
  dashboardObserverLastDisconnectedAt,
  dashboardObserverReconnectCount,
  dashboardObserverReady,
  dashboardObserverRejectedFrameCount,
  dashboardObserverLastRejectedFrameError,
} from '../dashboard-observer-state'
type BeaconState = 'green' | 'yellow' | 'red'

interface BeaconView {
  state: BeaconState
  label: string
  title: string
}

export function computeBeaconView(args: {
  connected: boolean
  ready: boolean
  lastEventAt: number
  eventCount60s: number
  lastActivityAt: number
  idleTimeoutMs: number | null
  now: number
}): BeaconView {
  if (!args.connected || !args.ready) {
    if (args.connected && !args.ready) {
      return {
        state: 'yellow',
        label: '연결 확인 중',
        title: 'Client SSE is awaiting observer admission.',
      }
    }
    return {
      state: 'red',
      label: '재연결 중',
      title: 'Client SSE is closed. Events will pause until reconnect. Server transport truth is in Diagnostics > Transport.',
    }
  }
  const age = args.lastActivityAt === 0 ? null : args.now - args.lastActivityAt
  const active = age !== null && args.idleTimeoutMs !== null && age < args.idleTimeoutMs
  return {
    state: active ? 'green' : 'yellow',
    label: active ? '연결됨' : '연결 확인 필요',
    title: active
      ? `Client SSE is active. ${args.eventCount60s} events / 60s; last stream bytes ${Math.floor(age / 1000)}s ago.`
      : 'Client SSE has no activity inside the server-advertised idle deadline.',
  }
}

// Tailwind classes per state.  Color tokens follow the existing
// dashboard design-system aliases to stay consistent with neighbouring
// status chips (ConnectionStatus, ErrorCounterBadge).
const STATE_CLASS: Record<BeaconState, string> = {
  green: 'text-[var(--color-status-ok)] bg-[var(--ok-soft)] border-[var(--color-status-ok)]',
  yellow: 'text-[var(--color-status-warn)] bg-[var(--warn-soft)] border-[var(--color-status-warn)]',
  red: 'text-[var(--color-status-err)] bg-[var(--bad-soft)] border-[var(--color-status-err)]',
}

const beaconView = computed<BeaconView>(() => computeBeaconView({
  connected: dashboardObserverConnected.value,
  ready: dashboardObserverReady.value,
  lastEventAt: dashboardObserverLastEventAt.value,
  eventCount60s: dashboardObserverEventCount60s.value,
  lastActivityAt: dashboardObserverLastActivityAt.value,
  idleTimeoutMs: dashboardObserverIdleTimeoutMs.value,
  now: Date.now(),
}))

export function TransportBeacon() {
  const view = beaconView.value
  const details = [view.title, `Reconnect attempts ${dashboardObserverReconnectCount.value}`]
  if (dashboardObserverRejectedFrameCount.value > 0) {
    details.push(`Discarded frames in this tab: ${dashboardObserverRejectedFrameCount.value}`)
    if (dashboardObserverLastRejectedFrameError.value) details.push(dashboardObserverLastRejectedFrameError.value)
  }
  if (dashboardObserverLastDisconnectedAt.value > 0) {
    details.push(`Last disconnected ${new Date(dashboardObserverLastDisconnectedAt.value).toLocaleTimeString()}`)
  }
  return html`
    <div
      class="v2-shell-panel flex items-center gap-1.5 whitespace-nowrap rounded-[var(--r-1)] border border-solid px-2 py-0.5 text-xs ${STATE_CLASS[view.state]}"
      title=${details.join(' · ')}
      role="status"
      data-beacon-state=${view.state}
    >
      <span class="status-text">${view.label}</span>
    </div>
  `
}
