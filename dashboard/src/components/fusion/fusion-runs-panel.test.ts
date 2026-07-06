import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { parseFusionRunsResponse } from '../../api/dashboard'
import { fusionRuns, fusionRunsError, fusionRunsLoading } from '../../store'
import {
  FusionRunsPanel,
  fusionRunPipelineSegments,
  fusionRunStatusText,
  fusionRunStatusTone,
} from './fusion-runs-panel'

describe('parseFusionRunsResponse', () => {
  it('maps snake_case rows to FusionRunRecord and falls back count to length', () => {
    const parsed = parseFusionRunsResponse({
      generated_at: '2026-06-20T01:00:00Z',
      runs: [
        { run_id: 'r-1', keeper: 'k1', preset: 'balanced', started_at: 100, status: 'running' },
        { run_id: 'r-2', keeper: 'k2', preset: 'deep', started_at: 200, status: 'completed' },
      ],
    })
    expect(parsed.generatedAt).toBe('2026-06-20T01:00:00Z')
    expect(parsed.count).toBe(2)
    expect(parsed.runs[0]).toEqual({
      runId: 'r-1',
      keeper: 'k1',
      preset: 'balanced',
      startedAt: 100,
      status: 'running',
    })
  })

  it('maps an unrecognized status to failed (never a healthy default) and drops rows without a run_id', () => {
    const parsed = parseFusionRunsResponse({
      runs: [
        { run_id: 'r-ok', keeper: 'k', preset: 'p', started_at: 1, status: 'weird' },
        { keeper: 'k', preset: 'p', started_at: 2, status: 'running' }, // no run_id -> dropped
      ],
    })
    expect(parsed.runs).toHaveLength(1)
    expect(parsed.runs[0]?.runId).toBe('r-ok')
    expect(parsed.runs[0]?.status).toBe('failed')
  })

  it('returns an empty, well-formed response for a non-object payload', () => {
    const parsed = parseFusionRunsResponse(null)
    expect(parsed.runs).toEqual([])
    expect(parsed.count).toBe(0)
    expect(parsed.generatedAt).toBeNull()
  })

  it('carries the additive error / failure_code fields on a failed row', () => {
    const parsed = parseFusionRunsResponse({
      runs: [
        {
          run_id: 'r-fail',
          keeper: 'k',
          preset: 'deep',
          started_at: 1,
          status: 'failed',
          error: 'judge timed out after 30s',
          failure_code: 'timeout',
        },
        { run_id: 'r-run', keeper: 'k', preset: 'p', started_at: 2, status: 'running' },
      ],
    })
    expect(parsed.runs[0]).toMatchObject({
      runId: 'r-fail',
      status: 'failed',
      error: 'judge timed out after 30s',
      failureCode: 'timeout',
    })
    // running rows carry no failure attribution
    expect(parsed.runs[1]?.error).toBeUndefined()
    expect(parsed.runs[1]?.failureCode).toBeUndefined()
  })
})

describe('fusion run status helpers', () => {
  it('maps status to the reused chip tone', () => {
    expect(fusionRunStatusTone('running')).toBe('warn')
    expect(fusionRunStatusTone('completed')).toBe('ok')
    expect(fusionRunStatusTone('failed')).toBe('bad')
  })

  it('keeps the wire label as the display text', () => {
    expect(fusionRunStatusText('running')).toBe('running')
    expect(fusionRunStatusText('completed')).toBe('completed')
    expect(fusionRunStatusText('failed')).toBe('failed')
  })

  it('maps registry status to a conservative backed pipeline', () => {
    expect(fusionRunPipelineSegments('running').map(segment => [segment.key, segment.state])).toEqual([
      ['keeper', 'done'],
      ['registry', 'done'],
      ['deliberation', 'active'],
      ['sink', 'pending'],
    ])
    expect(fusionRunPipelineSegments('completed').map(segment => segment.state)).toEqual([
      'done',
      'done',
      'done',
      'done',
    ])
    expect(fusionRunPipelineSegments('failed').map(segment => [segment.key, segment.state])).toEqual([
      ['keeper', 'done'],
      ['registry', 'done'],
      ['deliberation', 'failed'],
      ['sink', 'failed'],
    ])
  })
})

describe('FusionRunsPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    fusionRuns.value = []
    fusionRunsError.value = null
    fusionRunsLoading.value = false
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    fusionRuns.value = []
    fusionRunsError.value = null
    fusionRunsLoading.value = false
  })

  it('shows the empty state when there are no runs', () => {
    render(html`<${FusionRunsPanel} />`, container)
    expect(container.querySelector('[data-testid="fusion-runs-empty"]')).not.toBeNull()
    expect(container.textContent).toContain('No active or recent fusion runs')
  })

  it('shows a loading hint while empty and loading', () => {
    fusionRunsLoading.value = true
    render(html`<${FusionRunsPanel} />`, container)
    expect(container.textContent).toContain('Loading fusion runs')
  })

  it('renders a registry load error instead of the empty state', () => {
    fusionRunsError.value = 'HTTP 503 registry unavailable'

    render(html`<${FusionRunsPanel} />`, container)

    const error = container.querySelector('[data-testid="fusion-runs-error"]')
    expect(error).not.toBeNull()
    expect(error?.getAttribute('data-registry-source')).toBe('/api/v1/dashboard/fusion-runs')
    expect(error?.textContent).toContain('Registry load failed')
    expect(error?.textContent).toContain('HTTP 503 registry unavailable')
    expect(container.querySelector('[data-testid="fusion-runs-empty"]')).toBeNull()
    expect(container.textContent).not.toContain('No active or recent fusion runs')
  })

  it('keeps cached registry rows visible while surfacing the refresh error', () => {
    fusionRuns.value = [
      {
        runId: 'cached-failed',
        keeper: 'analyst',
        preset: 'trio',
        startedAt: 1_783_106_656,
        status: 'failed',
        error: 'fusion aborted: 0 of 3 panels answered',
        failureCode: 'panels_unavailable',
      },
    ]
    fusionRunsError.value = 'network offline'

    render(html`<${FusionRunsPanel} />`, container)

    expect(container.querySelector('[data-testid="fusion-runs-error"]')?.textContent).toContain('network offline')
    const cards = container.querySelectorAll('[data-testid="fusion-run-status-card"]')
    expect(cards).toHaveLength(1)
    expect(cards[0]?.getAttribute('data-run-id')).toBe('cached-failed')
    expect(cards[0]?.textContent).toContain('panels_unavailable')
    expect(container.textContent).not.toContain('No active or recent fusion runs')
  })

  it('renders one card per run with its status and a running indicator', () => {
    fusionRuns.value = [
      { runId: 'r-run', keeper: 'k1', preset: 'balanced', startedAt: 300, status: 'running' },
      { runId: 'r-done', keeper: 'k2', preset: 'deep', startedAt: 100, status: 'completed' },
      { runId: 'r-fail', keeper: 'k3', preset: 'deep', startedAt: 200, status: 'failed' },
    ]
    render(html`<${FusionRunsPanel} />`, container)

    const cards = container.querySelectorAll('[data-testid="fusion-run-status-card"]')
    expect(cards).toHaveLength(3)

    const byRun = (id: string) =>
      Array.from(cards).find(card => card.getAttribute('data-run-id') === id)
    expect(byRun('r-run')?.getAttribute('data-status')).toBe('running')
    expect(byRun('r-done')?.getAttribute('data-status')).toBe('completed')
    expect(byRun('r-fail')?.getAttribute('data-status')).toBe('failed')

    const runningPipeline = byRun('r-run')?.querySelector('[data-testid="fusion-run-pipeline"]')
    expect(runningPipeline?.querySelector('[data-stage="deliberation"]')?.getAttribute('data-state')).toBe('active')
    expect(runningPipeline?.querySelector('[data-stage="sink"]')?.getAttribute('data-state')).toBe('pending')
    expect(byRun('r-done')?.querySelector('[data-stage="sink"]')?.getAttribute('data-state')).toBe('done')
    expect(byRun('r-fail')?.querySelector('[data-stage="sink"]')?.getAttribute('data-state')).toBe('failed')

    // the running indicator counts only in-progress runs
    expect(container.textContent).toContain('1 running')
    expect(container.textContent).toContain('r-run')
    expect(container.textContent).toContain('k1')
  })

  it('omits the running indicator when nothing is in progress', () => {
    fusionRuns.value = [
      { runId: 'r-done', keeper: 'k2', preset: 'deep', startedAt: 100, status: 'completed' },
    ]
    render(html`<${FusionRunsPanel} />`, container)
    expect(container.querySelector('.fus-runs-live')).toBeNull()
  })

  it('surfaces the failure code and error on a failed run card', () => {
    fusionRuns.value = [
      {
        runId: 'r-fail',
        keeper: 'k3',
        preset: 'deep',
        startedAt: 200,
        status: 'failed',
        error: 'judge timed out after 30s',
        failureCode: 'timeout',
      },
    ]
    render(html`<${FusionRunsPanel} />`, container)
    const reason = container.querySelector('[data-testid="fusion-run-reason"]')
    expect(reason).not.toBeNull()
    expect(reason?.querySelector('.fus-runs-code')?.textContent).toBe('timeout')
    expect(reason?.textContent).toContain('judge timed out after 30s')
  })

  it('omits the reason line for a completed run', () => {
    fusionRuns.value = [
      { runId: 'r-done', keeper: 'k2', preset: 'deep', startedAt: 100, status: 'completed' },
    ]
    render(html`<${FusionRunsPanel} />`, container)
    expect(container.querySelector('[data-testid="fusion-run-reason"]')).toBeNull()
  })
})
