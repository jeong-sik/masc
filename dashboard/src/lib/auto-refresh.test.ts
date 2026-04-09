import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { formatAutoRefreshLabel, setupVisibleAutoRefresh } from './auto-refresh'

describe('auto-refresh', () => {
  const originalVisibility = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState')

  beforeEach(() => {
    vi.useFakeTimers()
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => 'visible',
    })
  })

  afterEach(() => {
    vi.clearAllTimers()
    vi.useRealTimers()
    if (originalVisibility) {
      Object.defineProperty(document, 'visibilityState', originalVisibility)
    }
  })

  it('formats labels from the configured interval', () => {
    expect(formatAutoRefreshLabel(30_000)).toBe('30초 자동 갱신')
    expect(formatAutoRefreshLabel(60_000)).toBe('1분 자동 갱신')
    expect(formatAutoRefreshLabel(500)).toBe('1초 자동 갱신')
  })

  it('deduplicates back-to-back visibility and focus refresh triggers', async () => {
    const refresh = vi.fn()
    const dispose = setupVisibleAutoRefresh(refresh, 30_000)

    document.dispatchEvent(new Event('visibilitychange'))
    window.dispatchEvent(new Event('focus'))
    await vi.advanceTimersByTimeAsync(0)

    expect(refresh).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(500)
    window.dispatchEvent(new Event('focus'))

    expect(refresh).toHaveBeenCalledTimes(2)
    dispose()
  })
})
