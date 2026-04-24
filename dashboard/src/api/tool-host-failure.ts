import { post } from './core'

interface ToolHostFailureReport {
  agent_name?: string
  client_name?: string
  tool_name: string
  transport?: string
  phase?: string
  message: string
  request_id?: string
  session_id?: string
  trace_id?: string
  timeout_ms?: number
}

export function reportToolHostFailure(
  report: ToolHostFailureReport,
): Promise<{ ok: boolean }> {
  return post('/api/v1/dashboard/logs/tool-host-failures', report, undefined, 3000)
}
