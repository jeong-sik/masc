import { html } from 'htm/preact'
import { act, cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { CandleSummary } from './candle-economy'
import { KeeperDetailHeaderInfo } from './keeper-detail-shell'
import { candleObservation, hydrateExecutionSnapshot, keepers, executionWorkspaceAuthority, invalidateExecutionSnapshotGeneration, resetExecutionSnapshotGeneration, refreshExecution } from '../store'

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
let epochSequence = 0
let fixtureEpoch = ''
let connectionGeneration = 0
beforeEach(() => {
  fixtureEpoch = `candle-ui-fixture-${++epochSequence}`
  generation = 0
  fetchDashboardExecution.mockReset()
  expect(invalidateExecutionSnapshotGeneration(fixtureEpoch, 0)).toBe(true)
})
function observe(candle: unknown, amount: unknown, root: string | undefined = '/fixture/currency-a') {
  const accepted = hydrateExecutionSnapshot({
    execution_publication_epoch: fixtureEpoch, execution_publication_generation: ++generation,
    status: { project: 'same-project', ...(root === undefined ? {} : { workspace_root: root }) },
    candle, keepers: [{ name: 'alpha', status: 'active', emoji: 'A', candle_balance_milli: amount }],
  }, { requestGeneration: connectionGeneration })
  expect(accepted).toBe(true)
}
afterEach(() => {
  cleanup()
  vi.clearAllTimers()
  vi.useRealTimers()
  keepers.value = []
  candleObservation.value = { status: 'unavailable', reason: 'Not yet read' }
})

describe('Candle existing screen consumers', () => {
  it('withdraws current currency when the real fetch path receives a warm-up envelope', async () => {
    vi.useFakeTimers()
    observe(ready, '9007199254740993')
    render(html`<${View} />`)
    expect(screen.getByTestId('keeper-candle-balance').textContent).toContain('9007199254740.993')
    fetchDashboardExecution.mockResolvedValue({ status: { project: 'initializing' } })
    await act(async () => { await refreshExecution({ immediate: true }) })
    expect(fetchDashboardExecution).toHaveBeenCalledTimes(1)
    expect(executionWorkspaceAuthority.peek()).toBeNull()
    expect(screen.getByTestId('candle-summary').textContent).not.toContain('18446744073709551614.000')
    expect(screen.getByTestId('keeper-candle-balance').textContent).not.toContain('9007199254740.993')
  })

  it('ignores a held warm-up reply after a newer pushed execution snapshot', async () => {
    vi.useFakeTimers()
    observe(ready, '1000')
    render(html`<${View} />`)
    let release!: (value: unknown) => void
    fetchDashboardExecution.mockReturnValue(new Promise(resolve => { release = resolve }))
    let pending!: Promise<void>
    await act(async () => {
      pending = refreshExecution({ force: true })
      await vi.advanceTimersByTimeAsync(0)
    })
    expect(fetchDashboardExecution).toHaveBeenCalledTimes(1)
    await act(async () => { observe(ready, '2000') })
    const authority = executionWorkspaceAuthority.peek()
    await act(async () => {
      release({ status: { project: 'initializing' } })
      await pending
    })
    expect(executionWorkspaceAuthority.peek()).toBe(authority)
    expect(screen.getByTestId('keeper-candle-balance').textContent).toBe('잔액 2.000 Candle')
    expect(candleObservation.peek().status).toBe('ready')
    await act(async () => { await vi.advanceTimersByTimeAsync(4_000) })
    expect(fetchDashboardExecution).toHaveBeenCalledTimes(1)
  })

  it('withdraws both summary and Keeper wallet through reconnect warm-up', async () => {
    observe(ready, '9007199254740993')
    render(html`<${View} />`)
    expect(screen.getByTestId('keeper-candle-balance').textContent).toContain('9007199254740.993')
    const oldConnection = connectionGeneration
    resetExecutionSnapshotGeneration()
    connectionGeneration += 1
    await waitFor(() => expect(screen.getByTestId('candle-summary').textContent).not.toContain('18446744073709551614.000'))
    expect(executionWorkspaceAuthority.peek()).toBeNull()
    expect(screen.getByTestId('keeper-candle-balance').textContent).not.toContain('9007199254740.993')
    expect(candleObservation.peek().status).toBe('unavailable')
    expect(hydrateExecutionSnapshot({
      execution_publication_epoch: fixtureEpoch, execution_publication_generation: ++generation,
      status: { workspace_root: '/fixture/currency-a' }, candle: ready,
      keepers: [{ name: 'alpha', candle_balance_milli: '9007199254740993' }],
    }, { requestGeneration: oldConnection })).toBe(false)
    const fresh = { status: 'ready', issued_milli: '2000', burned_milli: '0', circulating_milli: '2000' }
    observe(fresh, '2000', '/fixture/currency-b')
    await waitFor(() => expect(screen.getByTestId('keeper-candle-balance').textContent).toBe('잔액 2.000 Candle'))
    expect(screen.getByTestId('candle-summary').textContent).not.toContain('18446744073709551614.000')
  })

  it('refuses retained display roots and withdraws currency at epoch invalidation', async () => {
    observe(ready, '9007199254740993')
    render(html`<${View} />`)
    expect(hydrateExecutionSnapshot({
      execution_publication_epoch: fixtureEpoch, execution_publication_generation: ++generation,
      status: { project: 'same-project' }, candle: ready,
      keepers: [{ name: 'alpha', candle_balance_milli: '9007199254740993' }],
    }, { requestGeneration: connectionGeneration })).toBe(true)
    await waitFor(() => expect(screen.getByTestId('candle-summary').textContent).toContain('Current workspace identity unavailable'))
    expect(screen.getByTestId('keeper-candle-balance').textContent).not.toContain('9007199254740.993')
    observe(ready, '9007199254740993')
    await waitFor(() => expect(screen.getByTestId('keeper-candle-balance').textContent).toContain('9007199254740.993'))
    fixtureEpoch += '-new-server'
    expect(invalidateExecutionSnapshotGeneration(fixtureEpoch, generation)).toBe(true)
    await waitFor(() => expect(screen.getByTestId('candle-summary').textContent).not.toContain('18446744073709551614.000'))
    expect(screen.getByTestId('keeper-candle-balance').textContent).not.toContain('9007199254740.993')
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
