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

// Route an operator claim through the shared FSM transition tool so it is
// persisted server-side (todo -> claimed, assignee = the dashboard actor).
// Before this, the Work board's claim button only mutated local React state,
// so a claim vanished on refresh. masc_transition emits a task_resource
// notification, so the dashboard's task signal refreshes over SSE with the
// real assignee — the caller does not need a manual refetch.
export async function claimTask(taskId: string): Promise<void> {
  await callMcpTool('masc_transition', { task_id: taskId, action: 'claim' })
}

export type PurgeAgentResponse =
  | {
      ok: true
      accepted: true
      target_kind: 'keeper'
      agent_name: string
      keeper_name: string
      operation_id: string
    }
  | {
      ok: true
      accepted: false
      target_kind: 'agent'
      agent_name: string
      cleanup_results: Array<{
        agent_name: string
        heartbeats_stopped: number
        workspace_unbound: boolean
      }>
    }

export async function purgeAgent(agentName: string): Promise<PurgeAgentResponse> {
  return post<PurgeAgentResponse>('/api/v1/dashboard/agents/purge', {
    agent_name: agentName,
  })
}
