import { post, fetchWithTimeout } from './core'
import { ACTIVITY_TIMEOUT_MS } from '../config/constants'
import { callMcpTool } from './mcp'

// --- Control Dock ---

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
