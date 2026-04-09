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

  it('keeps short interval refreshes active while deduplicating follow-up focus events', async () => {
    const refresh = vi.fn()
    const dispose = setupVisibleAutoRefresh(refresh, 200)

    await vi.advanceTimersByTimeAsync(200)
    expect(refresh).toHaveBeenCalledTimes(1)

    window.dispatchEvent(new Event('focus'))
    expect(refresh).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(200)
    expect(refresh).toHaveBeenCalledTimes(2)
    dispose()
  })

  it('deduplicates an interval tick that lands right after an event-triggered refresh', async () => {
    const refresh = vi.fn()
    const dispose = setupVisibleAutoRefresh(refresh, 200)

    await vi.advanceTimersByTimeAsync(190)
    window.dispatchEvent(new Event('focus'))
    expect(refresh).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(10)
    expect(refresh).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(600)
    expect(refresh).toHaveBeenCalledTimes(2)
    dispose()
  })

  it('stops interval and event refreshes after cleanup', async () => {
    const refresh = vi.fn()
    const dispose = setupVisibleAutoRefresh(refresh, 200)

    dispose()
    window.dispatchEvent(new Event('focus'))
    document.dispatchEvent(new Event('visibilitychange'))
    await vi.advanceTimersByTimeAsync(1_000)

    expect(refresh).not.toHaveBeenCalled()
  })
})
