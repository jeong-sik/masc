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
// This flag lets operators turn the parallel mode off and run WS-only,
// eliminating the duplication once the WS transport is trusted in a
// given environment.  Default is false so existing deployments keep the
// safety net until explicitly opted in.
//
// Precedence (first match wins):
//   1. window.__MASC_DASHBOARD_WS_ONLY__ === true   (runtime injection)
//   2. import.meta.env.VITE_DASHBOARD_WS_ONLY === 'true'  (build time)
//   3. false

interface CutoverWindow extends Window {
  __MASC_DASHBOARD_WS_ONLY__?: unknown
}

export function dashboardWsOnlyEnabled(globalRef: Window = window): boolean {
  const runtime = (globalRef as CutoverWindow).__MASC_DASHBOARD_WS_ONLY__
  if (runtime === true) return true
  if (runtime === false) return false
  const env = import.meta.env?.VITE_DASHBOARD_WS_ONLY
  return env === 'true' || env === '1'
}
