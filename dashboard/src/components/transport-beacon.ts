// Transport beacon — operator-facing signal for the SSE → WS cutover.
//
// Renders a single chip for the browser's client channel only. Server-wide
// transport truth lives in the Transport Health panel backed by
// /api/v1/dashboard/transport-health.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { dashboardWsOnlyEnabled } from '../dashboard-ws-cutover'
import {
  dashboardWsConnected,
  dashboardWsEventCount60s,
  dashboardWsLastEventAt,
  dashboardWsLastPongAt,
  dashboardWsLastPongLatencyMs,
  dashboardWsReady,
  dashboardWsSseFallbackActive,
  dashboardWsSseFallbackReason,
} from '../dashboard-ws-state'
import {
  DASHBOARD_WS_HEARTBEAT_INTERVAL_MS,
  DASHBOARD_WS_RPC_TIMEOUT_MS,
} from '../config/constants'

// Resolved once per mount.  The cutover flag is build-time; runtime
// changes require a reload anyway, so caching avoids re-evaluating
// import.meta.env on every signal change.
const wsOnlyMode = dashboardWsOnlyEnabled()

// 30s of silence on a client WS channel turns the beacon yellow.  This is
// shorter than the typical heartbeat interval to flag truly idle
// transports without nuisance-firing on quiet workloads.
const SILENT_THRESHOLD_MS = 30_000
const HEARTBEAT_FRESH_MS = DASHBOARD_WS_HEARTBEAT_INTERVAL_MS + DASHBOARD_WS_RPC_TIMEOUT_MS + 1_000

type BeaconState = 'green' | 'yellow' | 'red' | 'gray'

interface BeaconView {
  state: BeaconState
  label: string
  title: string
}

export function computeBeaconView(args: {
  wsOnly: boolean
  connected: boolean
  ready: boolean
  lastEventAt: number
  eventCount60s: number
  lastPongAt: number
  lastPongLatencyMs: number | null
  sseFallbackActive: boolean
  sseFallbackReason: string | null
  now: number
}): BeaconView {
  if (!args.wsOnly) {
    return {
      state: 'gray',
      label: 'Client WS+SSE parallel',
      title: 'Client channel parallel mode. Server transport truth is in Transport Health. Set VITE_DASHBOARD_WS_ONLY=true to cut over.',
    }
  }
  if (!args.connected || !args.ready) {
    if (args.sseFallbackActive) {
      return {
        state: 'yellow',
        label: 'Client SSE fallback',
        title: args.sseFallbackReason
          ? `Client WS is degraded; SSE fallback is carrying events. Reason: ${args.sseFallbackReason}`
          : 'Client WS is degraded; SSE fallback is carrying events.',
      }
    }
    return {
      state: 'red',
      label: 'Client WS · disconnected',
      title: 'Client WS cutover mode, but the browser socket is closed. Events will pause until reconnect. Server transport truth is in Transport Health.',
    }
  }
  const silentMs = args.now - args.lastEventAt
  if (args.lastEventAt === 0 || silentMs > SILENT_THRESHOLD_MS) {
    const pongAgeMs = args.lastPongAt === 0
      ? Number.POSITIVE_INFINITY
      : args.now - args.lastPongAt
    if (pongAgeMs <= HEARTBEAT_FRESH_MS) {
      const latency = args.lastPongLatencyMs == null
        ? 'ok'
        : `${args.lastPongLatencyMs}ms`
      return {
        state: 'green',
        label: `Client WS · heartbeat · ${latency}`,
        title: `Client WS mode active. No route events, but heartbeat pong arrived ${Math.floor(pongAgeMs / 1000)}s ago.`,
      }
    }
    return {
      state: 'yellow',
      label: 'Client WS · silent',
      title: `Client WS mode has received no events for ${Math.floor(silentMs / 1000)}s and no fresh heartbeat pong. The workload may be idle or WS fan-out may be stuck.`,
    }
  }
  return {
    state: 'green',
    label: `Client WS · open · ${args.eventCount60s} deltas / 60s`,
    title: `Client WS mode active. Last applied route delta ${Math.floor(silentMs / 1000)}s ago. Heartbeats are shown separately when route deltas are idle.`,
  }
}

// Tailwind classes per state.  Color tokens follow the existing
// dashboard design-system aliases to stay consistent with neighbouring
// status chips (ConnectionStatus, ErrorCounterBadge).
const STATE_CLASS: Record<BeaconState, string> = {
  green: 'text-[var(--color-status-ok)] bg-[var(--ok-soft)] border-[var(--color-status-ok)]',
  yellow: 'text-[var(--color-status-warn)] bg-[var(--warn-soft)] border-[var(--color-status-warn)]',
  red: 'text-[var(--color-status-err)] bg-[var(--bad-soft)] border-[var(--color-status-err)]',
  gray: 'text-[var(--color-fg-muted)] bg-[var(--color-bg-elevated)] border-[var(--color-border-default)]',
}

const beaconView = computed<BeaconView>(() => computeBeaconView({
  wsOnly: wsOnlyMode,
  connected: dashboardWsConnected.value,
  ready: dashboardWsReady.value,
  lastEventAt: dashboardWsLastEventAt.value,
  eventCount60s: dashboardWsEventCount60s.value,
  lastPongAt: dashboardWsLastPongAt.value,
  lastPongLatencyMs: dashboardWsLastPongLatencyMs.value,
  sseFallbackActive: dashboardWsSseFallbackActive.value,
  sseFallbackReason: dashboardWsSseFallbackReason.value,
  now: Date.now(),
}))

export function TransportBeacon() {
  const view = beaconView.value
  return html`
    <div
      class="flex items-center gap-1.5 whitespace-nowrap rounded-[var(--r-1)] border border-solid px-2 py-0.5 text-xs ${STATE_CLASS[view.state]}"
      title=${view.title}
      role="status"
      data-beacon-state=${view.state}
    >
      <span class="status-text">${view.label}</span>
    </div>
  `
}
