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
  it('says nothing in the frame before the read was asked', () => {
    expect(keeperMonthEfficiencyView(nothing, 'alpha', true)).toEqual({ kind: 'not_asked' })
  })

  // Without a confirmed workspace the resource asks nothing. That is neither
  // a month without the Keeper nor a panel with nothing to say.
  it('says it has no workspace when none is confirmed', () => {
    expect(keeperMonthEfficiencyView(nothing, 'alpha', false)).toEqual({ kind: 'no_workspace' })
  })

  it('is reading while the first read is in flight', () => {
    expect(keeperMonthEfficiencyView({ ...nothing, loading: true }, 'alpha', true)).toEqual({ kind: 'reading' })
  })

  // A read that failed has no month to show. Drawing it as a month without
  // this Keeper would say the Keeper did nothing.
  it('keeps a failed first read apart from a month without the Keeper', () => {
    expect(keeperMonthEfficiencyView({ ...nothing, error: 'the read timed out' }, 'alpha', true))
      .toEqual({ kind: 'unread', reason: 'the read timed out' })
  })

  it('divides the totals of the Keeper by its turns', () => {
    const view = keeperMonthEfficiencyView({ ...nothing, data: month }, 'alpha', true)
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
    const view = keeperMonthEfficiencyView({ ...nothing, data: month }, 'tools-only', true)
    expect(view.kind === 'read' && view.share).toEqual({ kind: 'no_turn_counted', calls: 4, failed: 1 })
  })

  it('tells a Keeper with no row from a Keeper with a row', () => {
    const view = keeperMonthEfficiencyView({ ...nothing, data: month }, 'beta', true)
    expect(view.kind === 'read' && view.share).toEqual({ kind: 'absent' })
  })

  it('keeps the last numbers while a refresh runs and after it fails', () => {
    const refreshing = keeperMonthEfficiencyView({ data: month, loading: true, error: null }, 'alpha', true)
    expect(refreshing.kind === 'read' && refreshing.refresh).toEqual({ kind: 'refreshing' })
    expect(refreshing.kind === 'read' && refreshing.share.kind).toBe('measured')
    const failed = keeperMonthEfficiencyView({ data: month, loading: false, error: 'refused (503)' }, 'alpha', true)
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

// The panel reads only for a confirmed workspace. Both steps act on the
// module graph this test imports the panel from.
async function loadPanel(fetchMonth: FetchMonth) {
  vi.resetModules()
  vi.doMock('../api/dashboard-keeper-efficiency', async () => ({
    ...(await vi.importActual<typeof import('../api/dashboard-keeper-efficiency')>('../api/dashboard-keeper-efficiency')),
    fetchKeeperEfficiencyCurrentMonth: fetchMonth,
  }))
  const { confirmRuntimeTestWorkspace } = await import('../lib/runtime-workspace.test-fixture')
  const { invalidateExecutionSnapshotGeneration } = await import('../store')
  let withdrawals = 0
  return {
    panel: await import('./keeper-month-efficiency'),
    /** Confirms a workspace; called again, it confirms another one. */
    confirmWorkspace: confirmRuntimeTestWorkspace,
    /** A publication epoch the page has no snapshot of yet withdraws the
     *  accepted workspace (store.ts). */
    withdrawWorkspace: () => {
      withdrawals += 1
      invalidateExecutionSnapshotGeneration(`efficiency-panel-withdrawal-${withdrawals}`, 0)
    },
  }
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
  const buttonOf = (testId: string): HTMLButtonElement => {
    const button = container.querySelector<HTMLButtonElement>(`[data-testid="${testId}"]`)
    if (button === null) throw new Error(`no button ${testId} is drawn`)
    return button
  }
  const press = async (testId: string) => {
    const button = buttonOf(testId)
    await act(async () => { button.click() })
    await flushUi()
  }

  async function draw(
    fetchMonth: FetchMonth,
    keeperName: string,
    workspace: 'confirmed' | 'unconfirmed' = 'confirmed',
  ) {
    const loaded = await loadPanel(fetchMonth)
    if (workspace === 'confirmed') loaded.confirmWorkspace()
    const { KeeperMonthEfficiency } = loaded.panel
    const show = async (name: string) => {
      await act(async () => {
        render(html`<${KeeperMonthEfficiency} keeperName=${name} />`, container)
        await Promise.resolve()
      })
      await flushUi()
    }
    const change = async (step: () => void) => {
      await act(async () => { step() })
      await flushUi()
    }
    await show(keeperName)
    return {
      show,
      confirmWorkspace: () => change(loaded.confirmWorkspace),
      withdrawWorkspace: () => change(loaded.withdrawWorkspace),
    }
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

  // The Keeper page closes its detail when the Keeper changes, but the render
  // that carries the new name still draws this panel once. That render must
  // show the new Keeper's row and send no request the unmount would withdraw.
  it('picks the row of a new Keeper out of the answer it holds, without another request', async () => {
    const fetchMonth = vi.fn<FetchMonth>(async () => month)
    const { show } = await draw(fetchMonth, 'alpha')
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

    await press('keeper-month-efficiency-read')
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

    await press('keeper-month-efficiency-read')
    expect(fetchMonth).toHaveBeenCalledTimes(2)
    expect(state()).toBe('read')
    expect(drawn('data-efficiency-share')).toBe('measured')
    expect(drawn('data-efficiency-refresh')).toBe('failed')
    expect(container.querySelector('[role="alert"]')).not.toBeNull()
  })

  it('sends nothing for a press while a read runs', async () => {
    const second = pending<KeeperEfficiencyMonth>()
    const fetchMonth = vi.fn<FetchMonth>()
      .mockResolvedValueOnce(month)
      .mockReturnValueOnce(second.promise)
    await draw(fetchMonth, 'alpha')

    await press('keeper-month-efficiency-read')
    expect(drawn('data-efficiency-refresh')).toBe('refreshing')
    expect(fetchMonth).toHaveBeenCalledTimes(2)
    await press('keeper-month-efficiency-read')
    expect(fetchMonth).toHaveBeenCalledTimes(2)
    expect(drawn('data-efficiency-refresh')).toBe('refreshing')

    second.resolve(month)
    await flushUi()
    expect(drawn('data-efficiency-refresh')).toBe('settled')
    expect(fetchMonth).toHaveBeenCalledTimes(2)
  })

  // A disabled button drops keyboard focus, and so does a button that leaves
  // the page when it is pressed. The pressed button stays the same enabled
  // element from a failed read through the read again and a refresh.
  it('keeps the pressed button on the page, enabled, through every read', async () => {
    const again = pending<KeeperEfficiencyMonth>()
    const refresh = pending<KeeperEfficiencyMonth>()
    const fetchMonth = vi.fn<FetchMonth>()
      .mockRejectedValueOnce(new Error('refused (503)'))
      .mockReturnValueOnce(again.promise)
      .mockReturnValueOnce(refresh.promise)
    await draw(fetchMonth, 'alpha')
    expect(state()).toBe('unread')
    const pressed = buttonOf('keeper-month-efficiency-read')
    const held = () => {
      expect(buttonOf('keeper-month-efficiency-read')).toBe(pressed)
      expect(pressed.isConnected).toBe(true)
      expect(pressed.disabled).toBe(false)
    }

    await press('keeper-month-efficiency-read')
    expect(state()).toBe('reading')
    held()
    again.resolve(month)
    await flushUi()
    expect(state()).toBe('read')
    held()

    await press('keeper-month-efficiency-read')
    expect(drawn('data-efficiency-refresh')).toBe('refreshing')
    held()
    refresh.resolve(month)
    await flushUi()
    expect(drawn('data-efficiency-refresh')).toBe('settled')
    held()
    expect(fetchMonth).toHaveBeenCalledTimes(3)
  })

  it('draws the answer of a refresh in place of the one before', async () => {
    const later: KeeperEfficiencyMonth = {
      ...month,
      keepers: month.keepers.map(row => (row.keeper === 'tools-only' ? { ...row, turns: 2 } : row)),
    }
    const fetchMonth = vi.fn<FetchMonth>()
      .mockResolvedValueOnce(month)
      .mockResolvedValueOnce(later)
    await draw(fetchMonth, 'tools-only')
    expect(drawn('data-efficiency-share')).toBe('no_turn_counted')

    await press('keeper-month-efficiency-read')
    expect(drawn('data-efficiency-share')).toBe('measured')
    expect(drawn('data-efficiency-refresh')).toBe('settled')
  })

  it('waits for a workspace without asking, and reads once one is confirmed', async () => {
    const fetchMonth = vi.fn<FetchMonth>(async () => month)
    const page = await draw(fetchMonth, 'alpha', 'unconfirmed')
    expect(state()).toBe('no_workspace')
    expect(fetchMonth).not.toHaveBeenCalled()

    await page.confirmWorkspace()
    expect(fetchMonth).toHaveBeenCalledTimes(1)
    expect(state()).toBe('read')
    expect(drawn('data-efficiency-share')).toBe('measured')
  })

  // The numbers were read under the workspace that was withdrawn. They are
  // not the numbers of whatever workspace is confirmed next.
  it('drops the numbers of a withdrawn workspace and reads again under the next one', async () => {
    const fetchMonth = vi.fn<FetchMonth>(async () => month)
    const page = await draw(fetchMonth, 'alpha')
    expect(state()).toBe('read')

    await page.withdrawWorkspace()
    expect(state()).toBe('no_workspace')
    expect(fetchMonth).toHaveBeenCalledTimes(1)

    await page.confirmWorkspace()
    expect(fetchMonth).toHaveBeenCalledTimes(2)
    expect(state()).toBe('read')
  })

  it('withdraws its request when the workspace is withdrawn', async () => {
    const answer = pending<KeeperEfficiencyMonth>()
    const fetchMonth = vi.fn<FetchMonth>(() => answer.promise)
    const page = await draw(fetchMonth, 'alpha')
    const signal = fetchMonth.mock.calls[0]?.[0]?.signal
    expect(signal?.aborted).toBe(false)

    await page.withdrawWorkspace()
    expect(signal?.aborted).toBe(true)
    expect(state()).toBe('no_workspace')
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
