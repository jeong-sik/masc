// Dashboard push slice vocabulary shared by WS subscriptions and hydrators.
// Keep in sync with Server_mcp_transport_ws.valid_dashboard_slice.

export const DASHBOARD_PUSH_SLICES = [
  'shell',
  'namespace',
  'transport',
  'execution',
  'board',
  'composite',
  'operator',
] as const

export type DashboardPushSlice = typeof DASHBOARD_PUSH_SLICES[number]

export const GLOBAL_DASHBOARD_PUSH_SLICES = [
  'shell',
  'namespace',
  'transport',
] as const satisfies readonly DashboardPushSlice[]
