import { get, post } from './core'
import {
  callMcpTool,
  mcpCallFailureDisposition,
  mcpStructuredContentFromError,
} from './mcp'

// --- Control Dock ---

export type BroadcastSendReceipt = {
  ok: boolean
  requestId: string | null
  deliveryKind: 'passive' | 'accepted' | 'already_accepted' | 'pending' | 'deferred' | 'rejected' | 'outcome_unknown'
  reason: string | null
  workspacePersisted: boolean | null
}

export function broadcastReceiptMessage(receipt: BroadcastSendReceipt): string {
  if (receipt.ok) return 'Message sent.'
  if (receipt.deliveryKind === 'outcome_unknown') {
    return 'Broadcast outcome unknown. Do not resend until the workspace timeline is checked.'
  }
  const reason = receipt.reason ? `: ${receipt.reason}` : ''
  return `Workspace message persisted; Keeper intake ${receipt.deliveryKind}${reason}. Do not resend. request_id=${receipt.requestId}`
}

function parseBroadcastReceipt(receipt: unknown): BroadcastSendReceipt {
  if (typeof receipt !== 'object' || receipt === null || Array.isArray(receipt)) {
    throw new Error('Broadcast returned a malformed delivery receipt.')
  }
  const fields = receipt as Record<string, unknown>
  const requestId = typeof fields.request_id === 'string' ? fields.request_id : ''
  const delivery = fields.mention_delivery
  if (
    typeof fields.ok !== 'boolean'
    || !requestId
    || typeof delivery !== 'object'
    || delivery === null
    || Array.isArray(delivery)
  ) {
    throw new Error('Broadcast returned a malformed delivery receipt.')
  }
  const deliveryFields = delivery as Record<string, unknown>
  const kind = deliveryFields.kind
  if (
    kind !== 'passive'
    && kind !== 'accepted'
    && kind !== 'already_accepted'
    && kind !== 'pending'
    && kind !== 'deferred'
    && kind !== 'rejected'
  ) {
    throw new Error('Broadcast returned a malformed delivery receipt.')
  }
  const expectedOk = kind === 'passive' || kind === 'accepted' || kind === 'already_accepted'
  if (fields.ok !== expectedOk) {
    throw new Error('Broadcast returned a contradictory delivery receipt.')
  }
  return {
    ok: fields.ok,
    requestId,
    deliveryKind: kind,
    reason: typeof deliveryFields.reason === 'string' ? deliveryFields.reason : null,
    workspacePersisted: true,
  }
}

export async function sendBroadcast(_actorHint: string, content: string): Promise<BroadcastSendReceipt> {
  try {
    const text = await callMcpTool('masc_broadcast', { content })
    return parseBroadcastReceipt(JSON.parse(text))
  } catch (error) {
    const structured = mcpStructuredContentFromError(error)
    if (structured != null) {
      try {
        return parseBroadcastReceipt(structured)
      } catch {
        // A contradictory or malformed response cannot prove that the
        // workspace commit did not happen. Preserve uncertainty instead of
        // encouraging a duplicate resend.
        return {
          ok: false,
          requestId: null,
          deliveryKind: 'outcome_unknown',
          reason: 'Broadcast returned a malformed delivery receipt.',
          workspacePersisted: null,
        }
      }
    }
    if (mcpCallFailureDisposition(error) !== 'outcome_unknown') throw error
    return {
      ok: false,
      requestId: null,
      deliveryKind: 'outcome_unknown',
      reason: error instanceof Error ? error.message : 'unknown transport failure',
      workspacePersisted: null,
    }
  }
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
