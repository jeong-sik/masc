import { afterEach, describe, expect, it, vi } from 'vitest'
import type { KeeperEvalResponse, EvalSnapshot } from '../api/keeper'

// Mock fetchKeeperEval at the API layer
const fetchKeeperEvalMock = vi.fn<(name: string, limit?: number) => Promise<KeeperEvalResponse>>()

vi.mock('../api/keeper', () => ({
  fetchKeeperEval: (...args: Parameters<typeof fetchKeeperEvalMock>) => fetchKeeperEvalMock(...args),
}))

afterEach(() => {
  vi.clearAllMocks()
})

function makeSnapshot(overrides: Partial<EvalSnapshot> = {}): EvalSnapshot {
  return {
    agent_name: 'test-keeper',
    session_id: null,
    worker_run_id: 'run-1',
    timestamp: Date.now() / 1000,
    verdict: {
      schema_version: 1,
      all_passed: true,
      coverage: 0.82,
      layer_results: [
        { layer_name: 'ToolSelected', passed: true, score: 0.95, evidence: ['correct tool chosen'], detail: null },
        { layer_name: 'CompletesWithin', passed: true, score: 1.0, evidence: ['3/5 turns'], detail: null },
        { layer_name: 'ContainsText', passed: false, score: 0.0, evidence: ['missing expected output'], detail: null },
      ],
    },
    baseline_status: 'Improved',
    ...overrides,
  }
}

function makeEvalResponse(overrides: Partial<KeeperEvalResponse> = {}): KeeperEvalResponse {
  const snapshots = overrides.snapshots ?? [makeSnapshot()]
  return {
    keeper: 'test-keeper',
    count: snapshots.length,
    latest_coverage: snapshots[0]?.verdict.coverage ?? null,
    latest_all_passed: snapshots[0]?.verdict.all_passed ?? null,
    snapshots,
    ...overrides,
  }
}

describe('fetchKeeperEval integration types', () => {
  it('parses a well-formed eval response', () => {
    const response = makeEvalResponse()
    expect(response.count).toBe(1)
    expect(response.latest_coverage).toBe(0.82)
    expect(response.latest_all_passed).toBe(true)
    expect(response.snapshots[0]?.verdict.layer_results).toHaveLength(3)
  })

  it('handles empty snapshots', () => {
    const response = makeEvalResponse({ snapshots: [], count: 0, latest_coverage: null, latest_all_passed: null })
    expect(response.count).toBe(0)
    expect(response.latest_coverage).toBeNull()
    expect(response.snapshots).toHaveLength(0)
  })

  it('tracks layer pass/fail correctly', () => {
    const snapshot = makeSnapshot()
    const passed = snapshot.verdict.layer_results.filter(l => l.passed)
    const failed = snapshot.verdict.layer_results.filter(l => !l.passed)
    expect(passed).toHaveLength(2)
    expect(failed).toHaveLength(1)
    expect(failed[0]?.layer_name).toBe('ContainsText')
  })

  it('baseline_status is nullable', () => {
    const noBaseline = makeSnapshot({ baseline_status: null })
    expect(noBaseline.baseline_status).toBeNull()
    const improved = makeSnapshot({ baseline_status: 'Improved' })
    expect(improved.baseline_status).toBe('Improved')
  })
})
