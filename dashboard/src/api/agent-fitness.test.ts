import { afterEach, describe, expect, it, vi } from 'vitest'
import { fetchAgentFitness, parseAgentFitness } from './agent-fitness'
import { callMcpTool } from './mcp'
import { agentFitness, closeAgentDetail, refreshAgentDetail } from '../components/agent-detail-state'
import { selectedAgentName } from '../components/agent-detail-selection'

vi.mock('./mcp', () => ({ callMcpTool: vi.fn() }))
vi.mock('../api', async importOriginal => ({
  ...await importOriginal<typeof import('../api')>(),
  fetchWorkspaceMessages: vi.fn(async () => []),
  fetchAgentTimeline: vi.fn(async () => null),
}))

const pending = () => ({
  agent_id: ' Exact ',
  components: { completion: 0, task_lifecycle_success: null, speed: null, handoff_task_success: null },
  metrics: {
    agent_id: ' Exact ', period_start: 100, period_end: 200,
    outcome_basis: 'task_lifecycle', external_acceptance: { kind: 'unobserved', completed_tasks: 0 },
    record_count: 2, total_tasks: 1, conflicting_tasks: 0, completed_tasks: 0, successful_tasks: 0, failed_tasks: 0,
    avg_completion_time_s: null, task_completion_rate: 0, task_success_rate: null, error_rate: null,
    handoff_tasks: 1, completed_handoff_tasks: 0, successful_handoff_tasks: 0,
    handoff_task_success_rate: null, unique_collaborators: [],
  },
})
const response = (row: unknown = pending()) => ({ count: 1, agents: [row] })
const failed = () => ({
  agent_id: ' Exact ',
  components: { completion: 1, task_lifecycle_success: 0, speed: null, handoff_task_success: 0 },
  metrics: {
    ...pending().metrics, completed_tasks: 1, failed_tasks: 1, avg_completion_time_s: 0,
    external_acceptance: { kind: 'unobserved', completed_tasks: 1 },
    task_completion_rate: 1, task_success_rate: 0, error_rate: 1,
    completed_handoff_tasks: 1, handoff_task_success_rate: 0,
  },
})

afterEach(() => {
  closeAgentDetail()
  vi.clearAllMocks()
})

describe('named Task performance delivery', () => {
  it('keeps an absent observation distinct from pending outcomes and real zero results', async () => {
    vi.mocked(callMcpTool).mockResolvedValueOnce(JSON.stringify(response({
      agent_id: ' Exact ', components: null, metrics: null,
    })))
    expect(await fetchAgentFitness(' Exact ')).toBeNull()
    expect(callMcpTool).toHaveBeenCalledWith('masc_agent_fitness', { agent_name: ' Exact ', days: 7 })
    expect(parseAgentFitness(response(), ' Exact ')).toEqual(pending().components)
    expect(parseAgentFitness(response(failed()), ' Exact ')).toEqual(failed().components)
  })

  it('refuses another identity, population, missing fields and invented perfect handoff rates', () => {
    const row = pending()
    const invalid: unknown[] = [
      { count: 0, agents: [] },
      { count: 1, agents: [row, row] },
      response({ ...row, agent_id: 'Exact' }),
      response({ ...row, metrics: { ...row.metrics, agent_id: 'Exact' } }),
      response({ ...row, metrics: null }),
      response({ ...row, components: { completion: 0, task_lifecycle_success: null, speed: null } }),
      response({ ...row, components: { ...row.components, task_lifecycle_success: undefined } }),
      response({ ...row, components: { ...row.components, handoff_task_success: 1 } }),
      response({ ...row, metrics: { ...row.metrics, avg_completion_time_s: 0 } }),
      response({ ...row, metrics: { ...row.metrics, record_count: 0 } }),
      response({ ...row, metrics: { ...row.metrics, task_success_rate: 0 } }),
    ]
    for (const value of invalid) expect(() => parseAgentFitness(value, ' Exact ')).toThrow()
    expect(() => parseAgentFitness({ ...response(), count: 2 }, ' Exact ')).toThrow()
    expect(() => parseAgentFitness(response(), 'Exact')).toThrow()
  })

  it('retains unresolved Task evidence without inventing a completed outcome', () => {
    const row = pending()
    const conflicting = { ...row, metrics: { ...row.metrics, conflicting_tasks: 1 } }
    expect(parseAgentFitness(response(conflicting), ' Exact ')).toEqual(row.components)
    expect(() => parseAgentFitness(response({ ...conflicting,
      metrics: { ...conflicting.metrics, conflicting_tasks: 2 },
    }), ' Exact ')).toThrow()
    const completed = failed()
    expect(() => parseAgentFitness(response({ ...completed,
      metrics: { ...completed.metrics, conflicting_tasks: 1 },
    }), ' Exact ')).toThrow()
    for (const value of [-1, 0.5, NaN]) {
      expect(() => parseAgentFitness(response({ ...row,
        metrics: { ...row.metrics, conflicting_tasks: value },
      }), ' Exact ')).toThrow()
    }
  })

  it('scopes Task approval to lifecycle evidence and refuses invented external acceptance', () => {
    const row = failed()
    const approved = {
      ...row,
      components: { ...row.components, task_lifecycle_success: 1, handoff_task_success: 1 },
      metrics: { ...row.metrics, successful_tasks: 1, failed_tasks: 0,
        task_success_rate: 1, error_rate: 0, successful_handoff_tasks: 1, handoff_task_success_rate: 1 },
    }
    expect(parseAgentFitness(response(approved), ' Exact ')?.task_lifecycle_success).toBe(1)
    for (const metrics of [
      { ...approved.metrics, outcome_basis: 'external_acceptance' },
      { ...approved.metrics, external_acceptance: { kind: 'accepted', completed_tasks: 1 } },
      { ...approved.metrics, external_acceptance: { kind: 'unobserved', completed_tasks: 0 } },
    ]) {
      expect(() => parseAgentFitness(response({ ...approved, metrics }), ' Exact ')).toThrow()
    }
  })

  it('requires measured positive duration for a named speed score', () => {
    const zero = failed()
    const positive = { ...zero, components: { ...zero.components, speed: 1 },
      metrics: { ...zero.metrics, avg_completion_time_s: 4 } }
    expect(parseAgentFitness(response(positive), ' Exact ')?.speed).toBe(1)
    expect(() => parseAgentFitness(response({ ...zero,
      components: { ...zero.components, speed: 1 },
    }), ' Exact ')).toThrow()
    expect(() => parseAgentFitness(response({ ...positive,
      metrics: { ...positive.metrics, avg_completion_time_s: Infinity },
    }), ' Exact ')).toThrow()
  })

  it('passes nullable and zero outcomes through the actual detail refresh', async () => {
    selectedAgentName.value = ' Exact '
    vi.mocked(callMcpTool).mockResolvedValueOnce(JSON.stringify(response()))
    await refreshAgentDetail()
    expect(agentFitness.value).toEqual(pending().components)
    vi.mocked(callMcpTool).mockResolvedValueOnce(JSON.stringify(response(failed())))
    await refreshAgentDetail()
    expect(agentFitness.value).toEqual(failed().components)
  })
})
