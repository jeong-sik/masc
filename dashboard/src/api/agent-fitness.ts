import { isRecord } from '../components/common/normalize'
import { callMcpTool } from './mcp'

export interface AgentFitnessComponents {
  readonly completion: number
  readonly task_lifecycle_success: number | null
  readonly speed: number | null
  readonly handoff_task_success: number | null
}

function object(value: unknown, keys: readonly string[]): Record<string, unknown> {
  if (!isRecord(value) || Object.keys(value).length !== keys.length
    || !keys.every(key => Object.hasOwn(value, key))) {
    throw new Error('Invalid agent fitness object')
  }
  return value
}

function number(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new Error('Invalid fitness number')
  return value
}

function nullableNumber(value: unknown): number | null {
  return value === null ? null : number(value)
}

function rate(value: unknown): number | null {
  const result = nullableNumber(value)
  if (result !== null && (result < 0 || result > 1)) throw new Error('Invalid fitness rate')
  return result
}

/** A named query returns exactly that identity. Missing evidence stays null. */
export function parseAgentFitness(raw: unknown, agentName: string): AgentFitnessComponents | null {
  const root = object(raw, ['count', 'agents'])
  if (root.count !== 1 || !Array.isArray(root.agents) || root.agents.length !== 1) {
    throw new Error('Invalid named fitness population')
  }
  const row = object(root.agents[0], ['agent_id', 'components', 'metrics'])
  if (row.agent_id !== agentName) throw new Error('Fitness identity differs from selection')
  if (row.metrics === null && row.components === null) return null
  const metrics = object(row.metrics, [
    'agent_id', 'period_start', 'period_end', 'record_count', 'outcome_basis', 'external_acceptance', 'total_tasks', 'conflicting_tasks', 'completed_tasks',
    'successful_tasks', 'failed_tasks', 'avg_completion_time_s', 'task_completion_rate',
    'task_success_rate', 'error_rate', 'handoff_tasks', 'completed_handoff_tasks',
    'successful_handoff_tasks', 'handoff_task_success_rate', 'unique_collaborators',
  ])
  const components = object(row.components, ['completion', 'task_lifecycle_success', 'speed', 'handoff_task_success'])
  const count = (key: string): number => {
    const value = number(metrics[key])
    if (!Number.isSafeInteger(value) || value < 0) throw new Error('Invalid fitness count')
    return value
  }
  const records = count('record_count'), total = count('total_tasks'), completed = count('completed_tasks')
  const successful = count('successful_tasks'), failed = count('failed_tasks')
  const conflicting = count('conflicting_tasks')
  const acceptance = object(metrics.external_acceptance, ['kind', 'completed_tasks'])
  const handoffs = count('handoff_tasks'), completedHandoffs = count('completed_handoff_tasks')
  const successfulHandoffs = count('successful_handoff_tasks')
  const average = nullableNumber(metrics.avg_completion_time_s)
  const completion = number(components.completion), lifecycleSuccess = rate(components.task_lifecycle_success)
  const speed = rate(components.speed), handoff = rate(components.handoff_task_success)
  const ratio = (n: number, d: number): number | null => d === 0 ? null : n / d
  if (metrics.agent_id !== agentName || number(metrics.period_start) > number(metrics.period_end)
    || metrics.outcome_basis !== 'task_lifecycle' || acceptance.kind !== 'unobserved'
    || acceptance.completed_tasks !== completed
    || total === 0 || records < total || completed + conflicting > total || successful + failed !== completed
    || handoffs > total || completedHandoffs > Math.min(handoffs, completed)
    || successfulHandoffs > Math.min(completedHandoffs, successful)
    || completedHandoffs - successfulHandoffs > failed
    || handoffs - completedHandoffs > total - completed
    || (completed === 0 ? average !== null : average === null || average < 0)
    || completion !== completed / total || metrics.task_completion_rate !== completion
    || lifecycleSuccess !== ratio(successful, completed) || metrics.task_success_rate !== lifecycleSuccess
    || metrics.error_rate !== ratio(failed, completed)
    || handoff !== ratio(successfulHandoffs, completedHandoffs) || metrics.handoff_task_success_rate !== handoff
    || (average === null || average === 0 ? speed !== null : speed !== 1)
    || !Array.isArray(metrics.unique_collaborators)
    || !metrics.unique_collaborators.every(value => typeof value === 'string')) {
    throw new Error('Inconsistent named fitness observations')
  }
  return { completion, task_lifecycle_success: lifecycleSuccess, speed, handoff_task_success: handoff }
}

export async function fetchAgentFitness(agentName: string): Promise<AgentFitnessComponents | null> {
  const raw = await callMcpTool('masc_agent_fitness', { agent_name: agentName, days: 7 })
  return parseAgentFitness(JSON.parse(raw) as unknown, agentName)
}
