// @vitest-environment happy-dom
import { cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import { html } from 'htm/preact'
import {
  fetchKeeperEval,
  type EvalSnapshot,
  type KeeperEvalResponse,
} from '../api/keeper'
import {
  baselineLabel,
  evalPassTone,
  KeeperEvalQualityPanel,
} from './keeper-eval-quality'

vi.mock('../api/keeper', async () => {
  const actual = await vi.importActual<typeof import('../api/keeper')>('../api/keeper')
  return {
    ...actual,
    fetchKeeperEval: vi.fn(),
  }
})

const fetchKeeperEvalMock = vi.mocked(fetchKeeperEval)

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function evalResponse({
  allPassed = true,
  baselineStatus = 'Improved',
  coverage = 0.94,
}: {
  allPassed?: boolean
  baselineStatus?: string | null
  coverage?: number
} = {}): KeeperEvalResponse {
  return {
    keeper: 'keeper-1',
    count: 1,
    latest_coverage: coverage,
    latest_all_passed: allPassed,
    snapshots: [{
      agent_name: 'keeper-1',
      session_id: 'session-1',
      worker_run_id: 'run-1',
      timestamp: Date.now() / 1000,
      baseline_status: baselineStatus,
      verdict: {
        schema_version: 1,
        all_passed: allPassed,
        coverage,
        layer_results: [],
      },
    }],
  }
}

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

describe('eval quality status tones', () => {
  it.each([
    [true, 'ok'],
    [false, 'bad'],
  ] as const)('maps all_passed=%s to StatusChip tone %s', (allPassed, tone) => {
    expect(evalPassTone(allPassed)).toBe(tone)
  })

  it.each([
    ['Improved', 'ok'],
    ['Regressed', 'bad'],
    ['Unchanged', 'neutral'],
    ['Unknown', 'neutral'],
  ] as const)('maps baseline %s to StatusChip tone %s', (status, tone) => {
    expect(baselineLabel(status)).toEqual({ text: status, tone })
  })

  it('skips the baseline chip when status is empty', () => {
    expect(baselineLabel(null)).toBeNull()
  })
})

describe('KeeperEvalQualityPanel status chips', () => {
  it('renders eval verdict and baseline through StatusChip', async () => {
    fetchKeeperEvalMock.mockResolvedValue(evalResponse())

    render(html`<${KeeperEvalQualityPanel} keeperName="keeper-status-chip" />`)

    await waitFor(() => expect(fetchKeeperEvalMock).toHaveBeenCalledWith('keeper-status-chip', 20))

    const verdictChip = await screen.findByText('ALL PASS')
    const baselineChip = screen.getByText('Improved')

    expect(verdictChip.closest('[data-status-chip]')).toHaveAttribute('data-status-chip-tone', 'ok')
    expect(verdictChip.closest('[data-status-chip]')).toHaveAttribute('data-status-chip-uppercase', 'true')
    expect(baselineChip.closest('[data-status-chip]')).toHaveAttribute('data-status-chip-tone', 'ok')
    expect(baselineChip.closest('[data-status-chip]')).toHaveAttribute('data-status-chip-uppercase', 'false')
  })
})
