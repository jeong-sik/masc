import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  AutoresearchCycleRecord,
  AutoresearchLoopDetail,
  AutoresearchLoopSummary,
  AutoresearchLoopsResponse,
} from '../api/autoresearch'

function cycleRecord(cycle: number): AutoresearchCycleRecord {
  return {
    cycle,
    hypothesis: `hypothesis-${cycle}`,
    score_before: 0.5,
    score_after: 0.6,
    delta: 0.1,
    decision: 'keep',
    commit_hash: null,
    elapsed_ms: 10,
    model_used: 'glm',
    timestamp: 1_717_171_717 + cycle,
  }
}

function loopSummary(
  loop_id: string,
  overrides: Partial<AutoresearchLoopSummary> = {},
): AutoresearchLoopSummary {
  return {
    loop_id,
    goal: `Goal ${loop_id}`,
    metric_fn: 'echo 1',
    model_model: 'glm',
    target_file: `${loop_id}.ml`,
    status: 'running',
    current_cycle: 1,
    max_cycles: 5,
    baseline: 0.5,
    best_score: 0.6,
    best_cycle: 0,
    total_keeps: 1,
    total_discards: 0,
    elapsed_s: 30,
    updated_at: 1_717_171_717,
    live: true,
    workdir: `/tmp/${loop_id}`,
    source_workdir: '/tmp/source',
    program_note: null,
    warnings: [],
    insights: [],
    recent_cycles: [cycleRecord(0)],
    error: null,
    session_id: null,
    operation_id: null,
    linked_at: null,
    queued_hypothesis: null,
    ...overrides,
  }
}

function loopDetail(
  summary: AutoresearchLoopSummary,
  overrides: Partial<AutoresearchLoopDetail> = {},
): AutoresearchLoopDetail {
  return {
    ...summary,
    history: summary.recent_cycles,
    history_count: summary.recent_cycles.length,
    ...overrides,
  }
}

async function flushUi(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

async function loadComponentWithApi(api: {
  fetchAutoresearchLoops: () => Promise<AutoresearchLoopsResponse>
  fetchAutoresearchLoopDetail: (loopId: string) => Promise<AutoresearchLoopDetail>
}) {
  vi.resetModules()
  vi.doMock('../api', () => api)
  return import('./autoresearch')
}

describe('Autoresearch surface refresh', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('../api')
  })

  it('reloads selected detail when the surface refreshes', async () => {
    const loopA1 = loopSummary('loop-a111', { current_cycle: 1 })
    const loopA2 = loopSummary('loop-a111', { current_cycle: 2, best_score: 0.8 })
    const fetchLoops = vi.fn<() => Promise<AutoresearchLoopsResponse>>()
      .mockResolvedValueOnce({ loops: [loopA1], total: 1 })
      .mockResolvedValueOnce({ loops: [loopA2], total: 1 })
    const fetchDetail = vi.fn<(loopId: string) => Promise<AutoresearchLoopDetail>>()
      .mockResolvedValueOnce(loopDetail(loopA1, { history: [cycleRecord(0)], history_count: 1 }))
      .mockResolvedValueOnce(loopDetail(loopA2, { history: [cycleRecord(0), cycleRecord(1)], history_count: 2 }))

    const { Autoresearch, refreshAutoresearchSurface } = await loadComponentWithApi({
      fetchAutoresearchLoops: fetchLoops,
      fetchAutoresearchLoopDetail: fetchDetail,
    })

    render(html`<${Autoresearch} />`, container)
    await refreshAutoresearchSurface()
    await flushUi()

    expect(container.textContent).toContain('Research Brief')
    expect(container.textContent).toContain('이 화면은 generator loop 자체를 설명합니다.')
    expect(container.textContent).toContain('1 / 5')
    expect(container.textContent).toContain('사이클 이력 (1건)')

    const refreshButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('새로고침'))
    refreshButton?.click()
    await flushUi()

    expect(fetchLoops.mock.calls.length).toBeGreaterThanOrEqual(2)
    expect(fetchDetail.mock.calls.filter(([loopId]) => loopId === 'loop-a111').length)
      .toBeGreaterThanOrEqual(2)
    expect(container.textContent).toContain('2 / 5')
    expect(container.textContent).toContain('사이클 이력 (2건)')
  })

  it('preserves the current selection when that loop still exists after refresh', async () => {
    const loopA = loopSummary('loop-a111', { target_file: 'target-a.ml' })
    const loopB = loopSummary('loop-b222', { target_file: 'target-b.ml', current_cycle: 3 })
    const fetchLoops = vi.fn<() => Promise<AutoresearchLoopsResponse>>()
      .mockResolvedValueOnce({ loops: [loopA, loopB], total: 2 })
      .mockResolvedValueOnce({ loops: [loopA, { ...loopB, best_score: 0.9 }], total: 2 })
    const fetchDetail = vi.fn<(loopId: string) => Promise<AutoresearchLoopDetail>>()
      .mockResolvedValueOnce(loopDetail(loopA))
      .mockResolvedValueOnce(loopDetail(loopB))
      .mockResolvedValueOnce(loopDetail({ ...loopB, best_score: 0.9 }))

    const { Autoresearch, refreshAutoresearchSurface } = await loadComponentWithApi({
      fetchAutoresearchLoops: fetchLoops,
      fetchAutoresearchLoopDetail: fetchDetail,
    })

    render(html`<${Autoresearch} />`, container)
    await refreshAutoresearchSurface()
    await flushUi()

    const loopBButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('loop-b22'))
    loopBButton?.click()
    await flushUi()
    expect(container.textContent).toContain('target-b.ml')

    const refreshButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('새로고침'))
    refreshButton?.click()
    await flushUi()

    expect(fetchDetail).toHaveBeenLastCalledWith('loop-b222')
    expect(container.textContent).toContain('target-b.ml')
  })

  it('reselects the first loop when the previous selection disappears on refresh', async () => {
    const loopA = loopSummary('loop-a111', { target_file: 'target-a.ml' })
    const loopB = loopSummary('loop-b222', { target_file: 'target-b.ml' })
    const fetchLoops = vi.fn<() => Promise<AutoresearchLoopsResponse>>()
      .mockResolvedValueOnce({ loops: [loopA, loopB], total: 2 })
      .mockResolvedValueOnce({ loops: [loopA], total: 1 })
    const fetchDetail = vi.fn<(loopId: string) => Promise<AutoresearchLoopDetail>>()
      .mockResolvedValueOnce(loopDetail(loopA))
      .mockResolvedValueOnce(loopDetail(loopB))
      .mockResolvedValueOnce(loopDetail(loopA, { best_score: 0.95 }))

    const { Autoresearch, refreshAutoresearchSurface } = await loadComponentWithApi({
      fetchAutoresearchLoops: fetchLoops,
      fetchAutoresearchLoopDetail: fetchDetail,
    })

    render(html`<${Autoresearch} />`, container)
    await refreshAutoresearchSurface()
    await flushUi()

    const loopBButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('loop-b22'))
    loopBButton?.click()
    await flushUi()
    expect(container.textContent).toContain('target-b.ml')

    const refreshButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('새로고침'))
    refreshButton?.click()
    await flushUi()

    expect(fetchDetail).toHaveBeenLastCalledWith('loop-a111')
    expect(container.textContent).toContain('target-a.ml')
  })
})
