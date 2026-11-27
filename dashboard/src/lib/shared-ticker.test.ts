// @vitest-environment jsdom

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { cleanup, render } from '@testing-library/preact'
import { createSharedTicker, type SharedTicker } from './shared-ticker'

const TICK_MS = 5_000
const HOUR_MS = 3_600_000

function Clock({ ticker }: { readonly ticker: SharedTicker }) {
  ticker.use()
  return html`<span data-now>${ticker.signal.value}</span>`
}

describe('createSharedTicker', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-11-27T04:00:00Z'))
  })

  afterEach(() => {
    cleanup()
    vi.useRealTimers()
  })

  it('reads the clock when a consumer mounts after an idle stretch', () => {
    const ticker = createSharedTicker(TICK_MS)
    const first = render(html`<${Clock} ticker=${ticker} />`)
    first.unmount()

    vi.advanceTimersByTime(HOUR_MS)
    expect(Date.now() - ticker.signal.value).toBe(HOUR_MS)

    render(html`<${Clock} ticker=${ticker} />`)
    expect(ticker.signal.value).toBe(Date.now())
  })

  it('ticks on the interval while a consumer is mounted and stops after the last one leaves', () => {
    const ticker = createSharedTicker(TICK_MS)
    const view = render(html`<${Clock} ticker=${ticker} />`)
    const mountedAt = Date.now()

    vi.advanceTimersByTime(TICK_MS)
    expect(ticker.signal.value).toBe(mountedAt + TICK_MS)

    view.unmount()
    vi.advanceTimersByTime(TICK_MS * 3)
    expect(ticker.signal.value).toBe(mountedAt + TICK_MS)
  })
})
