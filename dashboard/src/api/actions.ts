import { get, post } from './core'
import { ACTIVITY_TIMEOUT_MS } from '../config/constants'
import { callMcpTool } from './mcp'
import {
  ActionsActivitySchemaDriftError,
  parseActivityGraphResponse,
  parseSwimlaneResponse,
  type ActivityGraphResponse,
  type SwimlaneResponse,
} from './schemas/actions-activity'

type ActivityFetchOptions = {
  signal?: AbortSignal
}

function isNotInitializedEnvelope(raw: unknown): boolean {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return false
  return (raw as { error?: unknown }).error === 'not initialized'
}

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

export function fetchTaskEvents(taskId: string, limit = 50): Promise<unknown[]> {
  const params = new URLSearchParams({
    task_id: taskId,
    limit: String(limit),
  })
  return get<unknown[]>(`/api/v1/dashboard/tasks/history?${params.toString()}`)
}

// --- Activity Graph ---

export async function fetchActivityGraph(
  since?: string,
  options: ActivityFetchOptions = {},
): Promise<ActivityGraphResponse | null> {
  const params = since ? `?since=${since}` : ''
  try {
    const raw = await get<unknown>(`/api/v1/activity/graph${params}`, {
      timeoutMs: ACTIVITY_TIMEOUT_MS,
      includeActorHeader: false,
      signal: options.signal,
    })
    if (isNotInitializedEnvelope(raw)) return null
    return parseActivityGraphResponse(raw)
  } catch (err) {
    if (err instanceof ActionsActivitySchemaDriftError) throw err
    console.debug('[activity] graph fetch failed', err instanceof Error ? err.message : err)
    throw err
  }
}

export async function fetchSwimlane(
  since?: string,
  options: ActivityFetchOptions = {},
): Promise<SwimlaneResponse | null> {
  const params = since ? `?since=${since}` : ''
  try {
    const raw = await get<unknown>(`/api/v1/activity/swimlane${params}`, {
      timeoutMs: ACTIVITY_TIMEOUT_MS,
      includeActorHeader: false,
      signal: options.signal,
    })
    if (isNotInitializedEnvelope(raw)) return null
    return parseSwimlaneResponse(raw)
  } catch (err) {
    if (err instanceof ActionsActivitySchemaDriftError) throw err
    console.debug('[activity] swimlane fetch failed', err instanceof Error ? err.message : err)
    throw err
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
