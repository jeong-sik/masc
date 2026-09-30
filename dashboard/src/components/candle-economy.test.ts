import { html } from 'htm/preact'
import { cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { CandleSummary } from './candle-economy'
import { KeeperDetailHeaderInfo } from './keeper-detail-shell'
import { candleObservation, hydrateExecutionSnapshot, keepers } from '../store'

vi.mock('../sse', () => ({ journal: { log: vi.fn() } }))

const ready = { status: 'ready', issued_milli: '18446744073709551614000', burned_milli: '1000', circulating_milli: '18446744073709551613000' } as const
function View() {
  const keeper = keepers.value[0]
  return html`<div><${CandleSummary} reading=${candleObservation.value} />${keeper
    ? html`<${KeeperDetailHeaderInfo} keeper=${keeper} titleId="keeper" phaseEnteredAtSec=${null} onClose=${() => {}} />`
    : null}</div>`
}
let generation = 0
function observe(candle: unknown, amount: unknown) {
  const accepted = hydrateExecutionSnapshot({ execution_publication_epoch: 'candle-ui-fixture', execution_publication_generation: ++generation, candle, keepers: [{ name: 'alpha', status: 'active', emoji: 'A', candle_balance_milli: amount }] })
  expect(accepted).toBe(true)
}
afterEach(() => { cleanup(); keepers.value = []; candleObservation.value = { status: 'unavailable', reason: 'Not yet read' } })

describe('Candle existing screen consumers', () => {
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
