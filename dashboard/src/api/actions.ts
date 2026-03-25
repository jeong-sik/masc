import { post, fetchWithTimeout } from './core'
import { ACTIVITY_TIMEOUT_MS } from '../config/constants'
import { callMcpTool } from './mcp'
import { isRecord } from '../components/common/normalize'
import { normalizeGovernanceCaseBundle, normalizeGovernanceExecutionOrder } from './board'
import type { GovernanceCaseBundle, GovernanceExecutionOrder } from '../types'

// --- Control Dock + Governance (MCP tools) ---

export async function sendBroadcast(agentName: string, message: string): Promise<void> {
  await callMcpTool('masc_broadcast', {
    agent_name: agentName,
    message,
  })
}

export async function fetchRoomMessages(limit = 40): Promise<string[]> {
  const text = await callMcpTool('masc_messages', { limit })
  return text
    .split('\n')
    .map(line => line.trim())
    .filter(line => line !== '')
}

export async function fetchTaskHistory(taskId: string, limit = 20): Promise<string> {
  return callMcpTool('masc_task_history', {
    task_id: taskId,
    limit,
  })
}

export async function submitGovernancePetition(title: string): Promise<GovernanceCaseBundle | null> {
  const text = await callMcpTool('masc_petition_submit', {
    title,
    origin: 'human',
    subject_type: 'task',
    risk_class: 'low',
    requested_action: {
      action_type: 'add_task',
      payload: { title },
    },
  })
  try {
    const raw = JSON.parse(text) as Record<string, unknown>
    const caseRaw = isRecord(raw.case) ? raw.case : null
    const petitionRaw = isRecord(raw.petition) ? raw.petition : null
    const rulingRaw = isRecord(raw.ruling) ? raw.ruling : null
    if (!caseRaw || !petitionRaw) return null
    return normalizeGovernanceCaseBundle({
      case: caseRaw,
      petitions: [petitionRaw],
      ruling: rulingRaw,
      execution_order: null,
    })
  } catch (err) {
    console.warn('[governance] petition response parse failed', err instanceof Error ? err.message : err)
    return null
  }
}

export async function submitGovernanceCaseBrief(
  caseId: string,
  stance: 'support' | 'oppose' | 'neutral',
  summary: string,
): Promise<GovernanceCaseBundle | null> {
  const text = await callMcpTool('masc_case_brief_submit', {
    case_id: caseId,
    stance,
    summary,
  })
  try {
    const raw = JSON.parse(text) as Record<string, unknown>
    const existing = normalizeGovernanceCaseBundle(raw)
    if (existing) return existing
  } catch (err) {
    console.debug('[governance] fast status update failed, falling back to full fetch', err instanceof Error ? err.message : err)
  }
  return fetchGovernanceCaseStatus(caseId)
}

export async function fetchGovernanceCaseStatus(caseId: string): Promise<GovernanceCaseBundle | null> {
  const text = await callMcpTool('masc_case_status', { case_id: caseId })
  try {
    return normalizeGovernanceCaseBundle(JSON.parse(text) as Record<string, unknown>)
  } catch (err) {
    console.warn('[governance] case status parse failed', err instanceof Error ? err.message : err)
    return null
  }
}

export async function decideGovernanceExecutionOrder(
  caseId: string,
  decision: 'confirm' | 'deny',
): Promise<GovernanceExecutionOrder | null> {
  const text = await callMcpTool('masc_execution_orders', {
    case_id: caseId,
    decision,
  })
  try {
    return normalizeGovernanceExecutionOrder(JSON.parse(text) as Record<string, unknown>)
  } catch (err) {
    console.warn('[governance] execution order parse failed', err instanceof Error ? err.message : err)
    return null
  }
}

// --- Activity Graph ---

export async function fetchActivityGraph(since?: string): Promise<import('../types').ActivityGraphResponse | null> {
  try {
    const params = since ? `?since=${since}` : ''
    const resp = await fetchWithTimeout(`/api/v1/activity/graph${params}`, {}, ACTIVITY_TIMEOUT_MS)
    if (!resp.ok) return null
    return (await resp.json()) as import('../types').ActivityGraphResponse
  } catch (err) {
    console.debug('[activity] graph fetch failed', err instanceof Error ? err.message : err)
    return null
  }
}

export async function fetchSwimlane(since?: string): Promise<import('../types').SwimlaneResponse | null> {
  try {
    const params = since ? `?since=${since}` : ''
    const resp = await fetchWithTimeout(`/api/v1/activity/swimlane${params}`, {}, ACTIVITY_TIMEOUT_MS)
    if (!resp.ok) return null
    return (await resp.json()) as import('../types').SwimlaneResponse
  } catch (err) {
    console.debug('[activity] swimlane fetch failed', err instanceof Error ? err.message : err)
    return null
  }
}

// --- Dashboard delete actions ---

export async function deleteBoardPost(postId: string): Promise<boolean> {
  const resp = await post<{ ok: boolean }>('/api/v1/dashboard/board/delete', { post_id: postId })
  return resp.ok
}

export async function deleteTask(taskId: string): Promise<boolean> {
  const resp = await post<{ ok: boolean }>('/api/v1/dashboard/tasks/delete', { task_id: taskId })
  return resp.ok
}

export async function deleteGoal(goalId: string): Promise<boolean> {
  const resp = await post<{ ok: boolean }>('/api/v1/dashboard/goals/delete', { goal_id: goalId })
  return resp.ok
}
