import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { KeeperEfficiencyMonth } from '../api/dashboard-keeper-efficiency'
import { keeperMonthEfficiencyView, type KeeperMonthEfficiencyRead } from './keeper-month-efficiency'

const month: KeeperEfficiencyMonth = {
  month: '2026-11',
  generated_at: 1794787200,
  days_covered: 15,
  fleet: {
    turns_total: 40,
    calls_per_turn: 5.5,
    tool_s_per_turn: 12.25,
    output_tokens_per_turn: 800,
    input_tokens_per_turn: 90000,
    cost_usd_per_turn: 0,
  },
  keepers: [
    {
      keeper: 'alpha',
      turns: 30,
      input_tokens: 3000000,
      output_tokens: 24000,
      cost_usd: 0,
      calls: 180,
      failed: 6,
      deferred: 2,
      tool_ms: 420000,
    },
    {
      keeper: 'tools-only',
      turns: 0,
      input_tokens: 0,
      output_tokens: 0,
      cost_usd: 0,
      calls: 4,
      failed: 1,
      deferred: 0,
      tool_ms: 900,
    },
  ],
}

const nothing: KeeperMonthEfficiencyRead = { data: null, loading: false, error: null }

describe('keeperMonthEfficiencyView', () => {
  it('says nothing before a read was asked', () => {
    expect(keeperMonthEfficiencyView(nothing, 'alpha')).toEqual({ kind: 'not_asked' })
  })

  it('is reading while the first read is in flight', () => {
    expect(keeperMonthEfficiencyView({ ...nothing, loading: true }, 'alpha')).toEqual({ kind: 'reading' })
  })

  // A read that failed has no month to show. Drawing it as a month without
  // this Keeper would say the Keeper did nothing.
  it('keeps a failed first read apart from a month without the Keeper', () => {
    expect(keeperMonthEfficiencyView({ ...nothing, error: 'the read timed out' }, 'alpha'))
      .toEqual({ kind: 'unread', reason: 'the read timed out' })
  })

  it('divides the totals of the Keeper by its turns', () => {
    const view = keeperMonthEfficiencyView({ ...nothing, data: month }, 'alpha')
    expect(view).toEqual({
      kind: 'read',
      month: '2026-11',
      daysCovered: 15,
      generatedAt: 1794787200,
      fleet: month.fleet,
      share: {
        kind: 'measured',
        turns: 30,
        callsPerTurn: 6,
        toolSecondsPerTurn: 14,
        outputTokensPerTurn: 800,
        calls: 180,
        failed: 6,
      },
      refresh: { kind: 'settled' },
    })
  })

  it('does not divide for a row with no counted turn', () => {
    const view = keeperMonthEfficiencyView({ ...nothing, data: month }, 'tools-only')
    expect(view.kind === 'read' && view.share).toEqual({ kind: 'no_turn_counted', calls: 4, failed: 1 })
  })

  it('tells a Keeper with no row from a Keeper with a row', () => {
    const view = keeperMonthEfficiencyView({ ...nothing, data: month }, 'beta')
    expect(view.kind === 'read' && view.share).toEqual({ kind: 'absent' })
  })

  it('keeps the last numbers while a refresh runs and after it fails', () => {
    const refreshing = keeperMonthEfficiencyView({ data: month, loading: true, error: null }, 'alpha')
    expect(refreshing.kind === 'read' && refreshing.refresh).toEqual({ kind: 'refreshing' })
    expect(refreshing.kind === 'read' && refreshing.share.kind).toBe('measured')
    const failed = keeperMonthEfficiencyView({ data: month, loading: false, error: 'refused (503)' }, 'alpha')
    expect(failed.kind === 'read' && failed.refresh).toEqual({ kind: 'failed', reason: 'refused (503)' })
    expect(failed.kind === 'read' && failed.share.kind).toBe('measured')
  })
})

type FetchMonth = (opts?: { signal?: AbortSignal }) => Promise<KeeperEfficiencyMonth>

async function flushUi(): Promise<void> {
  await act(async () => {
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
      await vi.advanceTimersByTimeAsync(0)
    }
  })
}

async function loadPanel(fetchMonth: FetchMonth) {
  vi.resetModules()
  vi.doMock('../api/dashboard-keeper-efficiency', async () => ({
    ...(await vi.importActual<typeof import('../api/dashboard-keeper-efficiency')>('../api/dashboard-keeper-efficiency')),
    fetchKeeperEfficiencyCurrentMonth: fetchMonth,
  }))
  // The panel reads only for a confirmed workspace; confirm it in the module
  // graph this test is about to import.
  const { confirmRuntimeTestWorkspace } = await import('../lib/runtime-workspace.test-fixture')
  confirmRuntimeTestWorkspace()
  return import('./keeper-month-efficiency')
}

function pending<T>() {
  let resolve!: (value: T) => void
  let reject!: (reason: unknown) => void
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

describe('KeeperMonthEfficiency', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    vi.useFakeTimers()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.resetModules()
    vi.doUnmock('../api/dashboard-keeper-efficiency')
    vi.useRealTimers()
  })

  const drawn = (name: string) =>
    container.querySelector('[data-efficiency-state]')?.getAttribute(name) ?? null
  const state = () => drawn('data-efficiency-state')
  const press = async (testId: string) => {
    const button = container.querySelector<HTMLButtonElement>(`[data-testid="${testId}"]`)
    if (button === null) throw new Error(`no button ${testId} is drawn`)
    await act(async () => { button.click() })
    await flushUi()
  }

  async function draw(fetchMonth: FetchMonth, keeperName: string) {
    const { KeeperMonthEfficiency } = await loadPanel(fetchMonth)
    const show = async (name: string) => {
      await act(async () => {
        render(html`<${KeeperMonthEfficiency} keeperName=${name} />`, container)
        await Promise.resolve()
      })
      await flushUi()
    }
    await show(keeperName)
    return show
  }

  it('reads once when drawn and shows the Keeper after the answer', async () => {
    const answer = pending<KeeperEfficiencyMonth>()
    const fetchMonth = vi.fn<FetchMonth>(() => answer.promise)
    await draw(fetchMonth, 'alpha')
    expect(fetchMonth).toHaveBeenCalledTimes(1)
    expect(state()).toBe('reading')

    answer.resolve(month)
    await flushUi()
    expect(state()).toBe('read')
    expect(drawn('data-efficiency-share')).toBe('measured')
    expect(drawn('data-efficiency-refresh')).toBe('settled')
  })

  it('asks nothing more when the page moves to another Keeper', async () => {
    const fetchMonth = vi.fn<FetchMonth>(async () => month)
    const show = await draw(fetchMonth, 'alpha')
    expect(drawn('data-efficiency-share')).toBe('measured')

    await show('beta')
    expect(drawn('data-efficiency-share')).toBe('absent')
    await show('tools-only')
    expect(drawn('data-efficiency-share')).toBe('no_turn_counted')
    expect(fetchMonth).toHaveBeenCalledTimes(1)
  })

  it('shows a failed read as unread and reads again when asked', async () => {
    const fetchMonth = vi.fn<FetchMonth>()
      .mockRejectedValueOnce(new Error('GET /api/v1/keeper-efficiency: timeout after 120000ms'))
      .mockResolvedValueOnce(month)
    await draw(fetchMonth, 'alpha')
    expect(state()).toBe('unread')
    expect(container.querySelector('[role="alert"]')).not.toBeNull()

    await press('keeper-month-efficiency-read-again')
    expect(fetchMonth).toHaveBeenCalledTimes(2)
    expect(state()).toBe('read')
    expect(drawn('data-efficiency-share')).toBe('measured')
  })

  it('keeps the numbers when a refresh fails, and says the refresh failed', async () => {
    const fetchMonth = vi.fn<FetchMonth>()
      .mockResolvedValueOnce(month)
      .mockRejectedValueOnce(new Error('refused (503)'))
    await draw(fetchMonth, 'alpha')
    expect(drawn('data-efficiency-refresh')).toBe('settled')

    await press('keeper-month-efficiency-refresh')
    expect(fetchMonth).toHaveBeenCalledTimes(2)
    expect(state()).toBe('read')
    expect(drawn('data-efficiency-share')).toBe('measured')
    expect(drawn('data-efficiency-refresh')).toBe('failed')
    expect(container.querySelector('[role="alert"]')).not.toBeNull()
  })

  it('cannot start a second refresh while one runs', async () => {
    const second = pending<KeeperEfficiencyMonth>()
    const fetchMonth = vi.fn<FetchMonth>()
      .mockResolvedValueOnce(month)
      .mockReturnValueOnce(second.promise)
    await draw(fetchMonth, 'alpha')

    await press('keeper-month-efficiency-refresh')
    expect(drawn('data-efficiency-refresh')).toBe('refreshing')
    const refresh = container.querySelector<HTMLButtonElement>('[data-testid="keeper-month-efficiency-refresh"]')
    expect(refresh?.disabled).toBe(true)

    second.resolve(month)
    await flushUi()
    expect(drawn('data-efficiency-refresh')).toBe('settled')
    expect(fetchMonth).toHaveBeenCalledTimes(2)
  })

  it('withdraws its request when the panel goes away', async () => {
    const answer = pending<KeeperEfficiencyMonth>()
    const fetchMonth = vi.fn<FetchMonth>(() => answer.promise)
    await draw(fetchMonth, 'alpha')
    const signal = fetchMonth.mock.calls[0]?.[0]?.signal
    expect(signal?.aborted).toBe(false)

    await act(async () => { render(null, container) })
    expect(signal?.aborted).toBe(true)
  })
})
