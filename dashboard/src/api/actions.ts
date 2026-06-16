import { get, post } from './core'
import { callMcpTool } from './mcp'

// --- Control Dock ---

export async function sendBroadcast(_actorHint: string, message: string): Promise<void> {
  await callMcpTool('masc_broadcast', {
    message,
  })
}

export async function fetchWorkspaceMessages(limit = 40): Promise<string[]> {
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

export function fetchTaskEvents(taskId: string, limit = 50): Promise<unknown[]> {
  const params = new URLSearchParams({
    task_id: taskId,
    limit: String(limit),
  })
  return get<unknown[]>(`/api/v1/dashboard/tasks/history?${params.toString()}`)
}

// --- Dashboard delete actions ---

export async function deleteBoardPost(postId: string): Promise<boolean> {
  const resp = await post<{ ok: boolean }>('/api/v1/dashboard/board/delete', { post_id: postId })
  return resp.ok
}

export async function setBoardPostPinned(postId: string, pinned: boolean): Promise<boolean> {
  const resp = await post<{ ok: boolean }>('/api/v1/dashboard/board/pin', { post_id: postId, pinned })
  return resp.ok
}

export async function deleteTask(taskId: string): Promise<boolean> {
  const resp = await post<{ ok: boolean }>('/api/v1/dashboard/tasks/delete', { task_id: taskId })
  return resp.ok
}

export interface PurgeAgentResponse {
  ok: boolean
  target_kind: 'agent' | 'keeper' | string
  agent_name: string
  keeper_name?: string
  removed_keeper_toml?: boolean
}

export async function purgeAgent(agentName: string): Promise<PurgeAgentResponse> {
  return post<PurgeAgentResponse>('/api/v1/dashboard/agents/purge', {
    agent_name: agentName,
  })
}
