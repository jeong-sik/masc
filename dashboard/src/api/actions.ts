import { get, post, fetchWithTimeout } from './core'
import { callMcpTool } from './mcp'
import { isRecord } from '../components/common/normalize'
import { asString, asNumber, asInt } from './parse-utils'
import { toIsoTimestamp, normalizeGovernanceCaseBundle, normalizeGovernanceExecutionOrder } from './board'
import type {
  GovernanceCaseBundle, GovernanceExecutionOrder, MdalIterationRecord, MdalLoop,
} from '../types'

// --- Karma ---

export function fetchKarma(): Promise<unknown> {
  return get('/api/v1/karma')
}

// --- Control Dock + Governance (MCP tools) ---

export async function sendBroadcast(agentName: string, message: string): Promise<void> {
  await callMcpTool('masc_broadcast', {
    agent_name: agentName,
    message,
  })
}

export async function addTaskFromDashboard(
  title: string,
  description: string,
  priority = 1,
): Promise<void> {
  await callMcpTool('masc_add_task', {
    title,
    description,
    priority,
  })
}

export async function joinDashboardAgent(agentName: string): Promise<string> {
  return callMcpTool('masc_join', {
    agent_name: agentName,
  })
}

export async function leaveDashboardAgent(agentName: string): Promise<void> {
  await callMcpTool('masc_leave', {
    agent_name: agentName,
  })
}

export async function sendAgentHeartbeat(agentName: string): Promise<void> {
  await callMcpTool('masc_heartbeat', {
    agent_name: agentName,
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

function normalizeMdalStatus(raw: unknown): MdalLoop['status'] {
  const text = asString(raw, '').trim().toLowerCase()
  if (text.startsWith('error')) return 'error'
  if (text === 'running' || text === 'interrupted' || text === 'completed' || text === 'stopped') return text
  return 'running'
}

function normalizeMdalIteration(raw: unknown): MdalIterationRecord | null {
  if (!isRecord(raw)) return null
  const evidenceRaw = isRecord(raw.evidence) ? raw.evidence : null
  return {
    iteration: asInt(raw.iteration) ?? 0,
    metric_before: asNumber(raw.metric_before, 0),
    metric_after: asNumber(raw.metric_after, 0),
    delta: asNumber(raw.delta, 0),
    changes: asString(raw.changes, ''),
    failed_attempts: asString(raw.failed_attempts, ''),
    next_suggestion: asString(raw.next_suggestion, ''),
    elapsed_ms: asInt(raw.elapsed_ms) ?? 0,
    cost_usd: typeof raw.cost_usd === 'number' && Number.isFinite(raw.cost_usd) ? raw.cost_usd : null,
    evidence: evidenceRaw
      ? {
          worker_engine: evidenceRaw.worker_engine === 'api_tool_loop' ? 'api_tool_loop' : 'api_tool_loop',
          worker_model: asString(evidenceRaw.worker_model, ''),
          tool_call_count: asInt(evidenceRaw.tool_call_count) ?? 0,
          tool_names: Array.isArray(evidenceRaw.tool_names)
            ? evidenceRaw.tool_names.filter((item): item is string => typeof item === 'string')
            : [],
          session_id: asString(evidenceRaw.session_id, ''),
          evidence_status:
            evidenceRaw.evidence_status === 'legacy_unverified'
              ? 'legacy_unverified'
              : 'verified',
        }
      : null,
  }
}

function normalizeMdalLoop(raw: unknown): MdalLoop | null {
  if (!isRecord(raw)) return null
  const loopId = asString(raw.loop_id, '').trim()
  if (!loopId) return null
  const history = Array.isArray(raw.history)
    ? raw.history
      .map(normalizeMdalIteration)
      .filter((row): row is MdalIterationRecord => row !== null)
    : []

  return {
    loop_id: loopId,
    profile: asString(raw.profile, 'custom'),
    status: normalizeMdalStatus(raw.status),
    strict_mode: typeof raw.strict_mode === 'boolean' ? raw.strict_mode : undefined,
    error_message: asString(raw.error_message) ?? asString(raw.error_reason) ?? null,
    stop_reason: asString(raw.stop_reason) ?? asString(raw.reason) ?? null,
    current_iteration: asInt(raw.iteration) ?? asInt(raw.current_iteration) ?? 0,
    max_iterations: asInt(raw.max_iterations) ?? 0,
    baseline_metric: asNumber(raw.baseline_metric, 0),
    current_metric: asNumber(raw.current_metric, asNumber(raw.baseline_metric, 0)),
    target: asString(raw.target, ''),
    stagnation_streak: asInt(raw.stagnation_streak) ?? 0,
    stagnation_limit: asInt(raw.stagnation_limit) ?? 0,
    elapsed_seconds: asNumber(raw.elapsed_seconds, 0),
    updated_at: raw.updated_at !== undefined ? toIsoTimestamp(raw.updated_at) : null,
    stopped_at: raw.stopped_at == null ? null : toIsoTimestamp(raw.stopped_at),
    execution_mode: raw.execution_mode === 'worker_spawn' ? 'worker_spawn' : undefined,
    worker_engine: raw.worker_engine === 'api_tool_loop' ? 'api_tool_loop' : null,
    worker_model: asString(raw.worker_model) ?? null,
    evidence_policy:
      raw.evidence_policy === 'legacy' || raw.evidence_policy === 'hard'
        ? raw.evidence_policy
        : undefined,
    latest_tool_call_count: asInt(raw.latest_tool_call_count) ?? 0,
    latest_tool_names: Array.isArray(raw.latest_tool_names)
      ? raw.latest_tool_names.filter((item): item is string => typeof item === 'string')
      : [],
    session_id: asString(raw.session_id) ?? null,
    evidence_status:
      raw.evidence_status === 'legacy_unverified'
        ? 'legacy_unverified'
        : raw.evidence_status === 'verified'
          ? 'verified'
          : null,
    durability:
      raw.durability === 'persistent_backend' || raw.durability === 'memory_only'
        ? raw.durability
        : undefined,
    persistence_backend:
      raw.persistence_backend === 'filesystem'
      || raw.persistence_backend === 'postgres'
      || raw.persistence_backend === 'memory'
        ? raw.persistence_backend
        : undefined,
    recoverable: typeof raw.recoverable === 'boolean' ? raw.recoverable : undefined,
    history,
  }
}

export type LatestMdalLoopResult =
  | { state: 'ready'; loop: MdalLoop }
  | { state: 'idle' }
  | { state: 'error'; message: string }

function isMdalIdleMessage(message: string): boolean {
  return message.trim().toLowerCase().includes('no mdal loop running')
}

export async function fetchLatestMdalLoop(): Promise<LatestMdalLoopResult> {
  try {
    const rawText = await callMcpTool('masc_mdal_status', {})
    const parsed = JSON.parse(rawText) as unknown
    const errorMessage = isRecord(parsed) ? asString(parsed.error, '').trim() : ''
    if (isMdalIdleMessage(errorMessage)) return { state: 'idle' }
    if (errorMessage) return { state: 'error', message: errorMessage }
    const loop = normalizeMdalLoop(parsed)
    return loop ? { state: 'ready', loop } : { state: 'error', message: 'Unexpected MDAL payload' }
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown MDAL fetch error'
    if (isMdalIdleMessage(message)) return { state: 'idle' }
    return { state: 'error', message }
  }
}

// --- Goal Store ---

export async function fetchGoals(): Promise<import('../types').Goal[]> {
  try {
    const res = await callMcpTool('masc_goal_list', {})
    if (typeof res === 'string') {
      const parsed = JSON.parse(res)
      return Array.isArray(parsed) ? parsed : parsed.goals ?? []
    }
    if (Array.isArray(res)) return res
    return (res as Record<string, unknown>).goals as import('../types').Goal[] ?? []
  } catch (err) {
    console.warn('[goals] fetch/parse error', err instanceof Error ? err.message : err)
    return []
  }
}

// --- Activity Graph ---

export async function fetchActivityGraph(since?: string): Promise<import('../types').ActivityGraphResponse | null> {
  try {
    const params = since ? `?since=${since}` : ''
    const resp = await fetchWithTimeout(`/api/v1/activity/graph${params}`, {}, 10000)
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
    const resp = await fetchWithTimeout(`/api/v1/activity/swimlane${params}`, {}, 10000)
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
