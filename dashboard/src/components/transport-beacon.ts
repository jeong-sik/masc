// Transport beacon — operator-facing signal for the SSE → WS cutover.
//
// Renders a single chip that tells the operator (a) which transport
// regime is active (WS-only vs parallel WS+SSE) and (b) whether events
// are actually flowing through the WS channel.  This is the eyes-on
// rollback signal: if the beacon turns yellow or red after a cutover,
// flip the env var and reload.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { dashboardWsOnlyEnabled } from '../dashboard-ws-cutover'
import {
  dashboardWsConnected,
  dashboardWsEventCount60s,
  dashboardWsLastEventAt,
  dashboardWsReady,
} from '../dashboard-ws-state'

// Resolved once per mount.  The cutover flag is build-time; runtime
// changes require a reload anyway, so caching avoids re-evaluating
// import.meta.env on every signal change.
const wsOnlyMode = dashboardWsOnlyEnabled()

// 30s of silence on a WS-only channel turns the beacon yellow.  This is
// shorter than the typical heartbeat interval to flag truly idle
// transports without nuisance-firing on quiet workloads.
const SILENT_THRESHOLD_MS = 30_000

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
  now: number
}): BeaconView {
  if (!args.wsOnly) {
    return {
      state: 'gray',
      label: 'WS+SSE (legacy)',
      title: 'Parallel mode — 두 transport 모두 active. cut over 하려면 VITE_DASHBOARD_WS_ONLY=true 설정.',
    }
  }
  if (!args.connected || !args.ready) {
    return {
      state: 'red',
      label: 'WS-only · disconnected',
      title: 'WS-only mode 인데 socket 이 닫혀있음. socket 재연결까지 event 가 도착하지 않음. Hot rollback: window.__MASC_DASHBOARD_WS_ONLY__ = false; location.reload()',
    }
  }
  const silentMs = args.now - args.lastEventAt
  if (args.lastEventAt === 0 || silentMs > SILENT_THRESHOLD_MS) {
    return {
      state: 'yellow',
      label: 'WS-only · silent',
      title: `WS-only mode 인데 최근 ${Math.floor(silentMs / 1000)}s 동안 event 없음. workload 가 실제 idle 이거나 WS fan-out 이 stuck.`,
    }
  }
  return {
    state: 'green',
    label: `WS-only · open · ${args.eventCount60s} events / 60s`,
    title: `WS-only mode active. 마지막 event ${Math.floor(silentMs / 1000)}s 전.`,
  }
}

// Tailwind classes per state.  Color tokens follow the existing
// dashboard design-system aliases to stay consistent with neighbouring
// status chips (ConnectionStatus, ErrorCounterBadge).
const STATE_CLASS: Record<BeaconState, string> = {
  green: 'text-[#9af3ba] bg-[var(--ok-soft)] border-[var(--color-status-ok)]',
  yellow: 'text-[#f3df9a] bg-[var(--warn-soft)] border-[var(--color-status-warn)]',
  red: 'text-[#f7b7b7] bg-[var(--bad-soft)] border-[var(--color-status-err)]',
  gray: 'text-[var(--color-fg-muted)] bg-[var(--white-4)] border-[var(--color-border-default)]',
}

const beaconView = computed<BeaconView>(() => computeBeaconView({
  wsOnly: wsOnlyMode,
  connected: dashboardWsConnected.value,
  ready: dashboardWsReady.value,
  lastEventAt: dashboardWsLastEventAt.value,
  eventCount60s: dashboardWsEventCount60s.value,
  now: Date.now(),
}))

export function TransportBeacon() {
  const view = beaconView.value
  return html`
    <div
      class="flex items-center gap-1.5 whitespace-nowrap rounded border border-solid px-2 py-0.5 text-xs ${STATE_CLASS[view.state]}"
      title=${view.title}
      role="status"
      data-beacon-state=${view.state}
    >
      <span class="status-text">${view.label}</span>
    </div>
  `
}
