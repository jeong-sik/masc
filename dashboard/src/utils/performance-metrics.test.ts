import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  startWebVitalsCapture,
  getWebVitalsSnapshot,
  resetWebVitalsSnapshot,
} from './performance-metrics'

describe('performance-metrics', () => {
  let observers: Array<{
    type: string
    callback: PerformanceObserverCallback
    entries: PerformanceEntryList
  }> = []

  beforeEach(() => {
    resetWebVitalsSnapshot()
    observers = []

    vi.stubGlobal(
      'PerformanceObserver',
      class MockPerformanceObserver {
        callback: PerformanceObserverCallback
        constructor(cb: PerformanceObserverCallback) {
          this.callback = cb
        }
        observe(init: PerformanceObserverInit) {
          const type = (init as Record<string, unknown>).type as string
          observers.push({ type, callback: this.callback, entries: [] })
        }
        disconnect() {
          observers = observers.filter((o) => o.callback !== this.callback)
        }
        takeRecords() {
          return []
        }
      },
    )

    vi.stubGlobal('performance', {
      getEntriesByType: vi.fn(),
    })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  function emitEntry(type: string, entry: PerformanceEntry) {
    for (const obs of observers) {
      if (obs.type === type) {
        obs.entries.push(entry)
        // Deliver only the new entry to match real PerformanceObserver behavior
        // (callback receives buffered entries since last invocation).
        obs.callback({ getEntries: () => [entry] } as PerformanceObserverEntryList, obs as unknown as PerformanceObserver)
      }
    }
  }

  it('captures TTFB from navigation timing', () => {
    const nav = {
      startTime: 0,
      responseStart: 120,
    } as PerformanceNavigationTiming
    ;(performance.getEntriesByType as ReturnType<typeof vi.fn>).mockReturnValue([nav])

    startWebVitalsCapture()
    expect(getWebVitalsSnapshot().ttfb).toBe(120)
  })

  it('captures FCP from paint observer', () => {
    ;(performance.getEntriesByType as ReturnType<typeof vi.fn>).mockReturnValue([])
    startWebVitalsCapture()

    emitEntry('paint', {
      name: 'first-contentful-paint',
      startTime: 250,
    } as PerformanceEntry)

    expect(getWebVitalsSnapshot().fcp).toBe(250)
  })

  it('captures LCP from largest-contentful-paint observer', () => {
    ;(performance.getEntriesByType as ReturnType<typeof vi.fn>).mockReturnValue([])
    startWebVitalsCapture()

    emitEntry('largest-contentful-paint', {
      startTime: 300,
    } as PerformanceEntry)

    emitEntry('largest-contentful-paint', {
      startTime: 600,
    } as PerformanceEntry)

    expect(getWebVitalsSnapshot().lcp).toBe(600)
  })

  it('accumulates CLS excluding shifts with recent input', () => {
    ;(performance.getEntriesByType as ReturnType<typeof vi.fn>).mockReturnValue([])
    startWebVitalsCapture()

    emitEntry('layout-shift', {
      startTime: 100,
      value: 0.05,
      hadRecentInput: false,
    } as unknown as PerformanceEntry)

    emitEntry('layout-shift', {
      startTime: 200,
      value: 0.03,
      hadRecentInput: true,
    } as unknown as PerformanceEntry)

    emitEntry('layout-shift', {
      startTime: 300,
      value: 0.02,
      hadRecentInput: false,
    } as unknown as PerformanceEntry)

    expect(getWebVitalsSnapshot().cls).toBe(0.07)
  })

  it('captures FID from first-input observer', () => {
    ;(performance.getEntriesByType as ReturnType<typeof vi.fn>).mockReturnValue([])
    startWebVitalsCapture()

    emitEntry('first-input', {
      startTime: 400,
      processingStart: 412,
    } as unknown as PerformanceEntry)

    expect(getWebVitalsSnapshot().fid).toBe(12)
  })

  it('exposes snapshot on window.__MASC_WEB_VITALS__', () => {
    ;(performance.getEntriesByType as ReturnType<typeof vi.fn>).mockReturnValue([])
    startWebVitalsCapture()

    const win = window as unknown as Record<string, unknown>
    expect(typeof win.__MASC_WEB_VITALS__).toBe('function')
    expect((win.__MASC_WEB_VITALS__ as () => unknown)()).toEqual(getWebVitalsSnapshot())
  })

  it('cleanup removes global property and disconnects observers', () => {
    ;(performance.getEntriesByType as ReturnType<typeof vi.fn>).mockReturnValue([])
    const cleanup = startWebVitalsCapture()

    expect(observers.length).toBeGreaterThan(0)
    cleanup()

    const win = window as unknown as Record<string, unknown>
    expect(win.__MASC_WEB_VITALS__).toBeUndefined()
    expect(observers.length).toBe(0)
  })

  it('returns nulls when no data is available', () => {
    ;(performance.getEntriesByType as ReturnType<typeof vi.fn>).mockReturnValue([])
    startWebVitalsCapture()
    const snap = getWebVitalsSnapshot()
    expect(snap.ttfb).toBeNull()
    expect(snap.fcp).toBeNull()
    expect(snap.lcp).toBeNull()
    expect(snap.cls).toBeNull()
    expect(snap.fid).toBeNull()
  })
})
