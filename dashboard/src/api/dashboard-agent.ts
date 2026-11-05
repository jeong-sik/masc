// MASC Dashboard — Agent timeline fetcher.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get } from './core'
import type { AgentTimelineResponse } from './schemas/agent-timeline'

export async function fetchAgentTimeline(
  agentName: string,
  sinceHours = 4,
  limit = 20,
): Promise<AgentTimelineResponse> {
  const raw = await get<unknown>(
    `/api/v1/agent-timeline?agent_name=${encodeURIComponent(agentName)}&since_hours=${sinceHours}&limit=${limit}`,
  )
  const { parseAgentTimelineResponse } = await import('./schemas/agent-timeline')
  return parseAgentTimelineResponse(raw)
}
