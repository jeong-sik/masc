// Dashboard WS cutover flag.
//
// The dashboard historically opened both an /sse EventSource and a /ws
// WebSocket in parallel.  The server fans every broadcast to both
// channels, so every event reaches the client twice — once through the
// direct SSE stream and once through the WS session's
// [Sse.subscribe_external] callback.  The client in turn processes each
// event twice: deltas land in the store via [applyDelta], raw pushes
// via the [routeServerPushEvent] call inside [handleRawPush].
//
// This flag controls the WS-only mode.
// As of recent updates, WS-only mode is the default (true) to reduce
// overhead and redundancy. You can opt-out by setting it to false.
//
// Precedence (first match wins):
//   1. window.__MASC_DASHBOARD_WS_ONLY__ === false  (runtime injection)
//   2. window.__MASC_DASHBOARD_WS_ONLY__ === true   (runtime injection)
//   3. import.meta.env.VITE_DASHBOARD_WS_ONLY === 'false' (build time)
//   4. true

interface CutoverWindow extends Window {
  __MASC_DASHBOARD_WS_ONLY__?: unknown
}

export function dashboardWsOnlyEnabled(globalRef: Window = window): boolean {
  const runtime = (globalRef as CutoverWindow).__MASC_DASHBOARD_WS_ONLY__
  if (runtime === false) return false
  if (runtime === true) return true
  const env = import.meta.env?.VITE_DASHBOARD_WS_ONLY
  if (env === 'false' || env === '0') return false
  return true
}
