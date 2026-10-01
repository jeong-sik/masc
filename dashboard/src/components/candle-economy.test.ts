import { html } from 'htm/preact'
import { act, cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { CandleSummary } from './candle-economy'
import { KeeperDetailHeaderInfo } from './keeper-detail-shell'
import {
  candleObservation, hydrateExecutionSnapshot,
  invalidateExecutionSnapshotGeneration, keepers, refreshExecution,
  resetExecutionSnapshotGeneration,
} from '../store'
import type { DashboardExecutionResponse } from '../types'

const fetchDashboardExecution = vi.hoisted(() => vi.fn())
vi.mock('../api/dashboard-execution', () => ({ fetchDashboardExecution }))

vi.mock('../sse', () => ({ journal: { log: vi.fn() } }))

const ready = { status: 'ready', issued_milli: '18446744073709551614000', burned_milli: '1000', circulating_milli: '18446744073709551613000' } as const
function View() {
  const keeper = keepers.value[0]
  return html`<div><${CandleSummary} reading=${candleObservation.value} />${keeper
    ? html`<${KeeperDetailHeaderInfo} keeper=${keeper} titleId="keeper" phaseEnteredAtSec=${null} onClose=${() => {}} />`
    : null}</div>`
}
let generation = 0
let fixtureSequence = 0
let fixtureEpoch = ''
let fixtureRequestGeneration = 0
function reconnect() {
  resetExecutionSnapshotGeneration()
  fixtureRequestGeneration += 1
}
function snapshot(candle: unknown, amount: unknown, root = '/fixture/candle-a'): DashboardExecutionResponse {
  return {
    execution_publication_epoch: fixtureEpoch,
    execution_publication_generation: ++generation,
    status: { project: 'candle-fixture', workspace_root: root },
    candle, keepers: [{ name: 'alpha', status: 'active', emoji: 'A', candle_balance_milli: amount }],
  } as DashboardExecutionResponse
}
function observe(candle: unknown, amount: unknown, root = '/fixture/candle-a') {
  const accepted = hydrateExecutionSnapshot(snapshot(candle, amount, root), {
    requestGeneration: fixtureRequestGeneration,
  })
  expect(accepted).toBe(true)
}
beforeEach(() => {
  fixtureEpoch = `candle-ui-fixture-${++fixtureSequence}`
  generation = 0
  expect(invalidateExecutionSnapshotGeneration(fixtureEpoch, 0)).toBe(true)
})
afterEach(() => {
  cleanup(); keepers.value = []
  candleObservation.value = { status: 'unavailable', reason: 'Not yet read' }
  vi.resetAllMocks(); vi.clearAllTimers(); vi.useRealTimers()
})

describe('Candle existing screen consumers', () => {
  it('withdraws supply and wallet on reconnect and warm-up, retaining the fleet until a ready HTTP read', async () => {
    observe(ready, '9007199254740993')
    render(html`<${View} />`)
    const retainedKeeper = keepers.value[0]
    vi.useFakeTimers()
    await act(async () => { reconnect() })
    expect(screen.getByTestId('candle-summary').textContent).not.toContain('18446744073709551614.000')
    expect(screen.getByTestId('keeper-candle-balance').textContent).not.toContain('9007199254740.993')
    expect(keepers.value[0]).toBe(retainedKeeper)

    fetchDashboardExecution.mockResolvedValueOnce({ status: { project: 'initializing' }, keepers: [] })
    await act(async () => {
      await expect(refreshExecution({ immediate: true })).rejects.toThrow('Execution projection is initializing')
    })
    expect(candleObservation.value.status).toBe('unavailable')
    expect(keepers.value[0]).toBe(retainedKeeper)
    const recovered = { status: 'ready', issued_milli: '7000', burned_milli: '2000', circulating_milli: '5000' }
    fetchDashboardExecution.mockResolvedValueOnce(snapshot(recovered, '500', '/fixture/candle-b'))
    await act(async () => { await refreshExecution({ immediate: true }) })
    expect(screen.getByTestId('candle-summary').textContent).toContain('7.000 Candle')
    expect(screen.getByTestId('keeper-candle-balance').textContent).toBe('잔액 0.500 Candle')

    // A successful warm-up without a reconnect also withdraws the accepted money.
    fetchDashboardExecution.mockResolvedValueOnce({ status: { project: 'initializing' } })
    await act(async () => {
      await expect(refreshExecution({ immediate: true })).rejects.toThrow('Execution projection is initializing')
    })
    expect(screen.getByTestId('candle-summary').textContent).not.toContain('7.000 Candle')
    expect(screen.getByTestId('keeper-candle-balance').textContent).not.toContain('0.500 Candle')
    fetchDashboardExecution.mockRejectedValueOnce(new Error('current endpoint failed'))
    await act(async () => {
      await expect(refreshExecution({ immediate: true })).rejects.toThrow('current endpoint failed')
    })
    expect(screen.getByTestId('candle-summary').textContent).toContain('current endpoint failed')
    expect(screen.getByTestId('keeper-candle-balance').textContent).toContain('Workspace authority is being verified')
    expect(keepers.value[0]?.name).toBe('alpha')
    fetchDashboardExecution.mockResolvedValueOnce(snapshot(recovered, '500', '/fixture/candle-b'))
    await act(async () => { await refreshExecution({ immediate: true }) })
    expect(screen.getByTestId('keeper-candle-balance').textContent).toBe('잔액 0.500 Candle')
  })

  it.each(['initializing', 'failure'] as const)('ignores a late %s response from before reconnect after current money recovers', async outcome => {
    observe(ready, '9007199254740993')
    render(html`<${View} />`)
    vi.useFakeTimers()
    let finish!: (data: DashboardExecutionResponse) => void
    let fail!: (error: Error) => void
    const held = new Promise<DashboardExecutionResponse>((resolve, reject) => { finish = resolve; fail = reject })
    let started!: () => void
    const requested = new Promise<void>(resolve => { started = resolve })
    fetchDashboardExecution.mockImplementationOnce(() => { started(); return held })
    let rejected!: Promise<void>
    await act(async () => {
      const refresh = refreshExecution({ immediate: true })
      rejected = expect(refresh).rejects.toThrow(
        outcome === 'initializing'
          ? 'Execution initialization was superseded by a newer observation'
          : 'Execution failure was superseded by a newer observation',
      )
      await requested
    })
    await act(async () => {
      reconnect()
      observe({ status: 'ready', issued_milli: '7000', burned_milli: '2000', circulating_milli: '5000' }, '500', '/fixture/candle-b')
    })
    await act(async () => {
      if (outcome === 'initializing') finish({ status: { project: 'initializing' } } as DashboardExecutionResponse)
      else fail(new Error('old endpoint failed'))
      await rejected
    })
    expect(screen.getByTestId('candle-summary').textContent).toContain('7.000 Candle')
    expect(screen.getByTestId('keeper-candle-balance').textContent).toBe('잔액 0.500 Candle')
    expect(vi.getTimerCount()).toBe(0)
  })

  it('hydrates an execution response into exact Overview totals and Keeper header balance', async () => {
    observe(ready, '9007199254740993')
    render(html`<${View} />`)
    expect(screen.getByTestId('candle-summary').textContent).toContain('18446744073709551614.000 Candle')
    expect(screen.getByTestId('candle-summary').textContent).toContain('18446744073709551613.000 Candle')
    expect(screen.getByTestId('keeper-candle-balance').textContent).toBe('잔액 9007199254740.993 Candle')
    observe({ status: 'disabled', reason: 'ledger unreadable' }, null)
    await waitFor(() => expect(screen.getByTestId('keeper-candle-balance').textContent).toContain('ledger unreadable'))
    expect(screen.getByTestId('candle-summary').textContent).not.toContain('18446744073709551614')
    observe({ status: 'off' }, null)
    await waitFor(() => expect(screen.queryByTestId('candle-summary')).toBeNull())
    expect(screen.queryByTestId('keeper-candle-balance')).toBeNull()
    observe(ready, '0')
    await waitFor(() => expect(screen.getByTestId('keeper-candle-balance').textContent).toBe('잔액 0.000 Candle'))
  })
  it('does not turn malformed or missing money into zero', async () => {
    observe(ready, 9007199254740993)
    render(html`<${View} />`)
    expect(screen.getByTestId('keeper-candle-balance').textContent).toContain('잔액 조회 불가')
    expect(screen.getByTestId('candle-summary').textContent).not.toContain('18446744073709551614.000')
    for (const [candle, amount] of [
      [ready, null], [ready, undefined],
      [{ status: 'off' }, '1'], [{ status: 'disabled', reason: 'ledger unreadable' }, '1'],
    ]) {
      observe(ready, '9007199254740993')
      await waitFor(() => expect(screen.getByTestId('keeper-candle-balance').textContent).toContain('9007199254740.993'))
      observe(candle, amount)
      await waitFor(() => expect(screen.getByTestId('candle-summary').textContent).toContain('Candle row balances disagree'))
      expect(screen.getByTestId('keeper-candle-balance').textContent).not.toContain('9007199254740.993')
    }
    observe(undefined, '0')
    await waitFor(() => expect(screen.getByTestId('candle-summary').textContent).toContain('Candle observation missing or malformed'))
    expect(screen.getByTestId('keeper-candle-balance').textContent).not.toContain('0.000 Candle')
  })
})
