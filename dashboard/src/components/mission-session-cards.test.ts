import { describe, expect, it } from 'vitest'
import type { DashboardProofWorkerRunEvidence } from '../types'
import { filterWorkerRuns } from './mission-session-cards'

function makeRun(
  overrides: Partial<DashboardProofWorkerRunEvidence> = {},
): DashboardProofWorkerRunEvidence {
  return {
    worker_run_id: 'run-x',
    tool_trace_refs: [],
    raw_evidence_refs: [],
    validation_failures: [],
    tool_surface_names: [],
    tool_surface_masc_names: [],
    tool_surface_shell_names: [],
    ...overrides,
  }
}

describe('filterWorkerRuns', () => {
  const runs: DashboardProofWorkerRunEvidence[] = [
    makeRun({
      worker_run_id: 'run-alpha-001',
      worker_name: 'worker-alpha',
      status: 'success',
      requested_model: 'gpt-5.4',
    }),
    makeRun({
      worker_run_id: 'run-beta-002',
      worker_name: 'worker-beta',
      status: 'failed',
      requested_model: 'claude-sonnet-4-6',
    }),
    makeRun({
      worker_run_id: 'run-gamma-003',
      worker_name: 'watcher-gamma',
      status: 'in_flight',
      requested_model: null,
    }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterWorkerRuns(runs, '')).toBe(runs)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterWorkerRuns(runs, '   ')).toBe(runs)
  })

  it('matches by worker_run_id substring (case-insensitive)', () => {
    const result = filterWorkerRuns(runs, 'RUN-ALPHA')
    expect(result).toHaveLength(1)
    expect(result[0]?.worker_run_id).toBe('run-alpha-001')
  })

  it('matches by worker_name substring', () => {
    const result = filterWorkerRuns(runs, 'watcher')
    expect(result.map(r => r.worker_run_id)).toEqual(['run-gamma-003'])
  })

  it('matches by status substring', () => {
    const result = filterWorkerRuns(runs, 'failed')
    expect(result.map(r => r.worker_run_id)).toEqual(['run-beta-002'])
  })

  it('matches by requested_model substring', () => {
    const result = filterWorkerRuns(runs, 'claude')
    expect(result.map(r => r.worker_run_id)).toEqual(['run-beta-002'])
  })

  it('returns empty when no field matches', () => {
    expect(filterWorkerRuns(runs, 'nonexistent-token')).toHaveLength(0)
  })

  it('trims query before matching', () => {
    expect(filterWorkerRuns(runs, '  alpha  ')).toHaveLength(1)
  })

  it('does not mutate the input array', () => {
    const copy = runs.slice()
    filterWorkerRuns(runs, 'alpha')
    expect(runs).toEqual(copy)
  })

  it('handles runs with null worker_name / status / requested_model safely', () => {
    const input: DashboardProofWorkerRunEvidence[] = [
      makeRun({
        worker_run_id: 'run-orphan',
        worker_name: null,
        status: null,
        requested_model: null,
      }),
    ]
    expect(filterWorkerRuns(input, 'orphan')).toHaveLength(1)
    expect(filterWorkerRuns(input, 'anything-else')).toHaveLength(0)
  })
})
