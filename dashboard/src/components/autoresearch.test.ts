import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  AutoresearchCycleRecord,
  AutoresearchLoopDetail,
  AutoresearchLoopSummary,
  AutoresearchLoopsResponse,
} from '../api/autoresearch'
import { filterCycles, cyclesSearchQuery } from './autoresearch-state'

void vi

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

function cycleWith(
  cycle: number,
  overrides: Partial<AutoresearchCycleRecord> = {},
): AutoresearchCycleRecord {
  return { ...cycleRecord(cycle), ...overrides }
}

function loopSummary(
  loop_id: string,
  overrides: Partial<AutoresearchLoopSummary> = {},
): AutoresearchLoopSummary {
  return {
    loop_id,
    author: null,
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
  retryAutoresearchLoop?: (loopId: string) => Promise<unknown>
  deleteAutoresearchLoop?: (loopId: string) => Promise<unknown>
}) {
  vi.resetModules()
  vi.doMock('../api', () => ({
    ...api,
    retryAutoresearchLoop: api.retryAutoresearchLoop ?? vi.fn().mockResolvedValue({ ok: true, action: 'retry' }),
    deleteAutoresearchLoop: api.deleteAutoresearchLoop ?? vi.fn().mockResolvedValue({ ok: true, action: 'delete' }),
    startAutoresearchLoop: (api as Record<string, unknown>).startAutoresearchLoop ?? vi.fn().mockResolvedValue({ ok: true, action: 'start' }),
  }))
  const module = await import('./autoresearch')
  module.resetAutoresearchState()
  return module
}

describe('Autoresearch surface refresh', () => {
  let container: HTMLDivElement
  let confirmMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    confirmMock = vi.fn(() => Promise.resolve(true))
    vi.doMock('./common/confirm-dialog', () => ({ requestConfirm: confirmMock }))
  })

  afterEach(async () => {
    const { resetAutoresearchState } = await import('./autoresearch')
    resetAutoresearchState()
    render(null, container)
    container.remove()
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('../api')
    vi.unstubAllGlobals()
  })

  it('reloads selected detail when the surface refreshes', async () => {
    const loopA1 = loopSummary('loop-a111', { current_cycle: 1 })
    const loopA2 = loopSummary('loop-a111', { current_cycle: 2, best_score: 0.8 })
    const fetchLoops = vi.fn<() => Promise<AutoresearchLoopsResponse>>(async () => {
      return { loops: [loopA2], total: 1 }
    })
      .mockResolvedValueOnce({ loops: [loopA1], total: 1 })
    const fetchDetail = vi.fn<(loopId: string) => Promise<AutoresearchLoopDetail>>(async () =>
      loopDetail(loopA2, { history: [cycleRecord(0), cycleRecord(1)], history_count: 2 }),
    )
      .mockResolvedValueOnce(loopDetail(loopA1, { history: [cycleRecord(0)], history_count: 1 }))

    const { Autoresearch, refreshAutoresearchSurface } = await loadComponentWithApi({
      fetchAutoresearchLoops: fetchLoops,
      fetchAutoresearchLoopDetail: fetchDetail,
    })

    render(html`<${Autoresearch} />`, container)
    await refreshAutoresearchSurface()
    await flushUi()

    expect(container.textContent).toContain('Experiment Outcomes')
    expect(container.textContent).toContain('하네스 열기')
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
  }, 20000)

  it('preserves the current selection when that loop still exists after refresh', async () => {
    const loopA = loopSummary('loop-a111', { target_file: 'target-a.ml' })
    const loopB = loopSummary('loop-b222', { target_file: 'target-b.ml', current_cycle: 3 })
    const refreshedLoopB = { ...loopB, best_score: 0.9 }
    const fetchLoops = vi.fn<() => Promise<AutoresearchLoopsResponse>>(async () => {
      return { loops: [loopA, refreshedLoopB], total: 2 }
    })
      .mockResolvedValueOnce({ loops: [loopA, loopB], total: 2 })
    let loopBDetailCalls = 0
    const fetchDetail = vi.fn<(loopId: string) => Promise<AutoresearchLoopDetail>>(async loopId => {
      if (loopId === 'loop-a111') return loopDetail(loopA)
      loopBDetailCalls += 1
      return loopBDetailCalls >= 2 ? loopDetail(refreshedLoopB) : loopDetail(loopB)
    })

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
    const refreshedLoopA = loopDetail(loopA, { best_score: 0.95 })
    const fetchLoops = vi.fn<() => Promise<AutoresearchLoopsResponse>>(async () => {
      return { loops: [loopA], total: 1 }
    })
      .mockResolvedValueOnce({ loops: [loopA, loopB], total: 2 })
    let loopADetailCalls = 0
    const fetchDetail = vi.fn<(loopId: string) => Promise<AutoresearchLoopDetail>>(async loopId => {
      if (loopId === 'loop-b222') return loopDetail(loopB)
      loopADetailCalls += 1
      return loopADetailCalls >= 2 ? refreshedLoopA : loopDetail(loopA)
    })

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

  it('offers a retry action for persisted error loops', async () => {
    const erroredLoop = loopSummary('loop-err0', {
      status: 'error',
      live: false,
      error: 'managed worktree missing',
      current_cycle: 0,
      max_cycles: 1,
    })
    const recoveredLoop = {
      ...erroredLoop,
      status: 'running' as const,
      live: true,
      error: null,
    }
    const fetchLoops = vi.fn<() => Promise<AutoresearchLoopsResponse>>()
      .mockResolvedValueOnce({ loops: [erroredLoop], total: 1 })
      .mockResolvedValueOnce({ loops: [recoveredLoop], total: 1 })
    const fetchDetail = vi.fn<(loopId: string) => Promise<AutoresearchLoopDetail>>()
      .mockResolvedValueOnce(loopDetail(erroredLoop))
      .mockResolvedValueOnce(loopDetail(recoveredLoop))
    const retryLoop = vi.fn<(loopId: string) => Promise<unknown>>()
      .mockResolvedValue({ ok: true, action: 'retry' })

    const { Autoresearch, refreshAutoresearchSurface } = await loadComponentWithApi({
      fetchAutoresearchLoops: fetchLoops,
      fetchAutoresearchLoopDetail: fetchDetail,
      retryAutoresearchLoop: retryLoop,
    })

    render(html`<${Autoresearch} />`, container)
    await refreshAutoresearchSurface()
    await flushUi()

    const retryButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('재시도'))
    const deleteButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('삭제'))

    expect(retryButton).toBeTruthy()
    expect(deleteButton).toBeTruthy()

    retryButton?.click()
    await flushUi()

    expect(retryLoop).toHaveBeenCalledWith('loop-err0')
    expect(container.textContent).toContain('진행 중')
  })

  it('offers a delete action for persisted error loops', async () => {
    const erroredLoop = loopSummary('loop-del0', {
      status: 'error',
      live: false,
      error: 'managed worktree missing',
      current_cycle: 0,
      max_cycles: 1,
    })
    const fetchLoops = vi.fn<() => Promise<AutoresearchLoopsResponse>>()
      .mockResolvedValueOnce({ loops: [erroredLoop], total: 1 })
      .mockResolvedValueOnce({ loops: [], total: 0 })
    const fetchDetail = vi.fn<(loopId: string) => Promise<AutoresearchLoopDetail>>()
      .mockResolvedValueOnce(loopDetail(erroredLoop))
    const deleteLoop = vi.fn<(loopId: string) => Promise<unknown>>()
      .mockResolvedValue({ ok: true, action: 'delete' })

    const { Autoresearch, refreshAutoresearchSurface } = await loadComponentWithApi({
      fetchAutoresearchLoops: fetchLoops,
      fetchAutoresearchLoopDetail: fetchDetail,
      deleteAutoresearchLoop: deleteLoop,
    })

    render(html`<${Autoresearch} />`, container)
    await refreshAutoresearchSurface()
    await flushUi()

    const deleteButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('삭제'))
    deleteButton?.click()
    await flushUi()

    expect(confirmMock).toHaveBeenCalledTimes(1)
    expect(deleteLoop).toHaveBeenCalledWith('loop-del0')
    expect(container.textContent).toContain('실행된 오토리서치 루프가 없습니다.')
  })

  it('does not delete when the confirmation is cancelled', async () => {
    confirmMock.mockReturnValueOnce(Promise.resolve(false))
    const erroredLoop = loopSummary('loop-del1', {
      status: 'error',
      live: false,
      error: 'managed worktree missing',
      current_cycle: 0,
      max_cycles: 1,
    })
    const fetchLoops = vi.fn<() => Promise<AutoresearchLoopsResponse>>()
      .mockResolvedValueOnce({ loops: [erroredLoop], total: 1 })
    const fetchDetail = vi.fn<(loopId: string) => Promise<AutoresearchLoopDetail>>()
      .mockResolvedValueOnce(loopDetail(erroredLoop))
    const deleteLoop = vi.fn<(loopId: string) => Promise<unknown>>()
      .mockResolvedValue({ ok: true, action: 'delete' })

    const { Autoresearch, refreshAutoresearchSurface } = await loadComponentWithApi({
      fetchAutoresearchLoops: fetchLoops,
      fetchAutoresearchLoopDetail: fetchDetail,
      deleteAutoresearchLoop: deleteLoop,
    })

    render(html`<${Autoresearch} />`, container)
    await refreshAutoresearchSurface()
    await flushUi()

    const deleteButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('삭제'))
    deleteButton?.click()
    await flushUi()

    expect(confirmMock).toHaveBeenCalledTimes(1)
    expect(deleteLoop).not.toHaveBeenCalled()
    expect(container.textContent).toContain('managed worktree missing')
  })

  it('shows loop action errors and re-enables buttons after a failed retry', async () => {
    const erroredLoop = loopSummary('loop-err1', {
      status: 'error',
      live: false,
      error: 'managed worktree missing',
      current_cycle: 0,
      max_cycles: 1,
    })
    const fetchLoops = vi.fn<() => Promise<AutoresearchLoopsResponse>>()
      .mockResolvedValueOnce({ loops: [erroredLoop], total: 1 })
    const fetchDetail = vi.fn<(loopId: string) => Promise<AutoresearchLoopDetail>>()
      .mockResolvedValueOnce(loopDetail(erroredLoop))
    const retryLoop = vi.fn<(loopId: string) => Promise<unknown>>()
      .mockRejectedValue(new Error('retry failed'))

    const { Autoresearch, refreshAutoresearchSurface } = await loadComponentWithApi({
      fetchAutoresearchLoops: fetchLoops,
      fetchAutoresearchLoopDetail: fetchDetail,
      retryAutoresearchLoop: retryLoop,
    })

    render(html`<${Autoresearch} />`, container)
    await refreshAutoresearchSurface()
    await flushUi()

    const retryButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('재시도')) as HTMLButtonElement | undefined
    const deleteButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('삭제')) as HTMLButtonElement | undefined
    retryButton?.click()
    await flushUi()

    expect(retryLoop).toHaveBeenCalledWith('loop-err1')
    expect(container.textContent).toContain('retry failed')
    expect(retryButton?.disabled).toBe(false)
    expect(deleteButton?.disabled).toBe(false)
  })

  it('disables loop action buttons while a retry is in flight', async () => {
    const erroredLoop = loopSummary('loop-err2', {
      status: 'error',
      live: false,
      error: 'managed worktree missing',
      current_cycle: 0,
      max_cycles: 1,
    })
    const fetchLoops = vi.fn<() => Promise<AutoresearchLoopsResponse>>()
      .mockResolvedValueOnce({ loops: [erroredLoop], total: 1 })
      .mockResolvedValueOnce({ loops: [erroredLoop], total: 1 })
    const fetchDetail = vi.fn<(loopId: string) => Promise<AutoresearchLoopDetail>>()
      .mockResolvedValueOnce(loopDetail(erroredLoop))
      .mockResolvedValueOnce(loopDetail(erroredLoop))
    let resolveRetry!: () => void
    const retryLoop = vi.fn<(loopId: string) => Promise<unknown>>()
      .mockImplementation(
        () =>
          new Promise<void>(resolve => {
            resolveRetry = () => resolve()
          }),
      )

    const { Autoresearch, refreshAutoresearchSurface } = await loadComponentWithApi({
      fetchAutoresearchLoops: fetchLoops,
      fetchAutoresearchLoopDetail: fetchDetail,
      retryAutoresearchLoop: retryLoop,
    })

    render(html`<${Autoresearch} />`, container)
    await refreshAutoresearchSurface()
    await flushUi()

    const retryButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('재시도')) as HTMLButtonElement | undefined
    retryButton?.click()
    await flushUi()

    const busyRetryButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('복구 중...')) as HTMLButtonElement | undefined
    const busyDeleteButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('삭제')) as HTMLButtonElement | undefined

    expect(busyRetryButton?.disabled).toBe(true)
    expect(busyDeleteButton?.disabled).toBe(true)

    resolveRetry()
    await flushUi()

    const settledRetryButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('재시도')) as HTMLButtonElement | undefined
    expect(settledRetryButton?.disabled).toBe(false)
  })
})

describe('filterCycles', () => {
  afterEach(() => {
    cyclesSearchQuery.value = ''
  })

  const cycles: readonly AutoresearchCycleRecord[] = [
    cycleWith(1, { hypothesis: 'Reduce memory footprint', decision: 'keep' }),
    cycleWith(2, { hypothesis: 'Try CUDA kernel fusion', decision: 'discard' }),
    cycleWith(3, { hypothesis: 'Cache embeddings in LRU', decision: 'keep' }),
  ]

  it('returns the input reference unchanged for an empty query', () => {
    const result = filterCycles(cycles, '')
    expect(result).toBe(cycles)
  })

  it('returns the input reference unchanged for a whitespace-only query', () => {
    const result = filterCycles(cycles, '   ')
    expect(result).toBe(cycles)
  })

  it('matches hypothesis substring (case-insensitive)', () => {
    const result = filterCycles(cycles, 'CUDA')
    expect(result).toHaveLength(1)
    expect(result[0]?.cycle).toBe(2)
  })

  it('matches hypothesis substring with mixed case query', () => {
    const result = filterCycles(cycles, 'MEMORY')
    expect(result).toHaveLength(1)
    expect(result[0]?.cycle).toBe(1)
  })

  it('matches raw decision keyword `keep`', () => {
    const result = filterCycles(cycles, 'keep')
    expect(result.map(c => c.cycle)).toEqual([1, 3])
  })

  it('matches raw decision keyword `discard`', () => {
    const result = filterCycles(cycles, 'discard')
    expect(result).toHaveLength(1)
    expect(result[0]?.decision).toBe('discard')
  })

  it('matches localized decision label (유지 / 삭제)', () => {
    expect(filterCycles(cycles, '유지').map(c => c.cycle)).toEqual([1, 3])
    const discard = filterCycles(cycles, '삭제')
    expect(discard).toHaveLength(1)
    expect(discard[0]?.decision).toBe('discard')
  })

  it('trims leading and trailing whitespace before matching', () => {
    const result = filterCycles(cycles, '   cache   ')
    expect(result).toHaveLength(1)
    expect(result[0]?.cycle).toBe(3)
  })

  it('returns an empty array when nothing matches', () => {
    const result = filterCycles(cycles, 'nonexistent-term-zzz')
    expect(result).toEqual([])
  })

  it('does not match numeric cycle or score fields', () => {
    // cycle=1 exists, but "1" should not match as hypothesis/decision.
    const result = filterCycles(cycles, '0.5')
    expect(result).toEqual([])
  })
})
