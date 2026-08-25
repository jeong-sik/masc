// Dashboard push slice vocabulary shared by WS subscriptions and hydrators.
//
// Every name here must be BOTH accepted by Server_mcp_transport_ws
// .valid_dashboard_slice AND producible by dashboard_slice_for_sse_type --
// a slice the server accepts but can never emit is a subscription that
// silently never delivers.
//
// 'shell', 'goals' and 'board' were exactly that. They were filled by
// dashboard/subscribe's one-shot snapshot provider, never by deltas; #27027
// deleted that provider when it made subscribe ACK-only. 'shell' remains a
// live surface over its REST endpoint (/api/v1/dashboard/shell, polled by
// refreshShell); board events still reach the client raw-forwarded; the goal
// loop feed behind 'goals' was removed by RFC-0352.
export const DASHBOARD_PUSH_SLICES = [
  'namespace',
  'transport',
  'execution',
  'composite',
  'operator',
] as const

export type DashboardPushSlice = typeof DASHBOARD_PUSH_SLICES[number]

export const GLOBAL_DASHBOARD_PUSH_SLICES = [
  'namespace',
  'transport',
] as const satisfies readonly DashboardPushSlice[]
