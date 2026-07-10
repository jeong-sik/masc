// k6 WebSocket load harness — masc dashboard
//
// Tracks: PR-0.2.G (sibling of PR-0.2.B WS histogram #12015, PR-0.2.F
// perf-baseline.yml). IMPLEMENTATION-QUEUE Q-P1-7 (Track C C-5).
//
// Targets the dashboard same-origin WebSocket upgrade. Default scenario
// holds 100 sustained virtual users for 30 seconds. CI runs a 5-VU 5-second
// smoke variant; real 100-VU measurement runs on a dedicated production
// runner per docs/design/perf-baseline-protocol.md scope.
//
// Thresholds (Track A line 1063 / IMPLEMENTATION-QUEUE Phase 1 SLO):
//   - ws_connecting     p(95) < 500ms  (initial network handshake)
//   - sync_latency_ms   p(95) < 100ms  (broadcast → recv application-level)
//   - msg-received rate > 99%
//
// Configurable via env:
//   MASC_DASHBOARD_WS_URL  (default ws://127.0.0.1:8935/ws)
//   MASC_DASHBOARD_BEARER  (optional non-browser Authorization bearer)
//   K6_VUS                 (default 100)
//   K6_DURATION            (default 30s)
//   K6_HOLD_MS             (default 20000 — connection hold per VU)

import ws from 'k6/ws'
import { check, sleep } from 'k6'
import { Trend } from 'k6/metrics'

const syncLatency = new Trend('sync_latency_ms')

const targetUrl =
  __ENV.MASC_DASHBOARD_WS_URL || 'ws://127.0.0.1:8935/ws'
const authToken = __ENV.MASC_DASHBOARD_BEARER || ''
const vus = parseInt(__ENV.K6_VUS || '100', 10)
const duration = __ENV.K6_DURATION || '30s'
const holdMs = parseInt(__ENV.K6_HOLD_MS || '20000', 10)

export const options = {
  scenarios: {
    sustained: {
      executor: 'constant-vus',
      vus,
      duration,
    },
  },
  thresholds: {
    ws_connecting: ['p(95)<500'],
    sync_latency_ms: ['p(95)<100'],
    'checks{type:msg-received}': ['rate>0.99'],
    'checks{type:connect}': ['rate>0.99'],
  },
  // Tag every metric so threshold groups stay narrow.
  tags: {
    harness: 'ws-100vu',
    track: 'PR-0.2.G',
  },
}

export default function () {
  const sentAt = new Map() // request-id -> ts (ms)
  const headers = { 'Sec-WebSocket-Protocol': 'masc.dashboard.v1' }
  if (authToken) headers.Authorization = `Bearer ${authToken}`

  const res = ws.connect(targetUrl, { headers }, function (socket) {
    socket.on('open', function () {
      const helloId = `hello-${__VU}-${Date.now()}`
      sentAt.set(helloId, Date.now())
      socket.send(
        JSON.stringify({
          jsonrpc: '2.0',
          id: helloId,
          method: 'dashboard/hello',
          params: {
            protocol: 'dashboard-ws.v1',
            features: ['snapshot', 'delta', 'mode_snapshot'],
          },
        })
      )
    })

    socket.on('message', function (data) {
      // Application-level latency: time since *some* outbound message.
      // For broadcast frames we have no request-id round-trip, so we use
      // Date.now() - sentAt(any) as a coarse upper bound.
      const anySentAt = Math.min(...sentAt.values())
      if (Number.isFinite(anySentAt)) {
        syncLatency.add(Date.now() - anySentAt)
      }
      check(
        data,
        {
          'message received': (d) =>
            typeof d === 'string' && d.length > 0,
        },
        { type: 'msg-received' }
      )
    })

    socket.on('error', function (e) {
      // CI runs without a live server; expected to fail at WS connect or
      // immediately after. Real measurement runs on a dedicated runner.
      console.warn(`ws error (expected in CI): ${e.error()}`)
    })

    socket.setTimeout(function () {
      socket.close()
    }, holdMs)
  })

  check(
    res,
    {
      'connect status 101': (r) => r && r.status === 101,
    },
    { type: 'connect' }
  )

  sleep(1)
}
