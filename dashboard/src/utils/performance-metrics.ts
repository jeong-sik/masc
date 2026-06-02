// Synthetic web-vitals capture using native Performance API.
// Collects TTFB, FCP, LCP, CLS, and FID without external libraries.
// Snapshot is exposed on window.__MASC_WEB_VITALS__ for Playwright/vitest consumption.

export interface WebVitalsSnapshot {
  ttfb: number | null
  fcp: number | null
  lcp: number | null
  cls: number | null
  fid: number | null
}

let snapshot: WebVitalsSnapshot = {
  ttfb: null,
  fcp: null,
  lcp: null,
  cls: null,
  fid: null,
}

export function getWebVitalsSnapshot(): WebVitalsSnapshot {
  return { ...snapshot }
}

export function resetWebVitalsSnapshot(): void {
  snapshot = { ttfb: null, fcp: null, lcp: null, cls: null, fid: null }
}

interface LayoutShiftEntry extends PerformanceEntry {
  value: number
  hadRecentInput: boolean
}

interface FirstInputEntry extends PerformanceEntry {
  processingStart: number
}

/** Start capturing web-vitals. Returns a cleanup function. */
export function startWebVitalsCapture(): () => void {
  // TTFB from navigation timing
  try {
    const navEntries = performance.getEntriesByType('navigation') as PerformanceNavigationTiming[]
    if (navEntries.length > 0) {
      const nav = navEntries[0]!
      snapshot.ttfb = nav.responseStart - nav.startTime
    }
  } catch {
    // Ignore if PerformanceNavigationTiming is unavailable
  }

  // FCP
  let paintObserver: PerformanceObserver | null = null
  try {
    paintObserver = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        if (entry.name === 'first-contentful-paint') {
          snapshot.fcp = entry.startTime
        }
      }
    })
    paintObserver.observe({ type: 'paint', buffered: true } as PerformanceObserverInit)
  } catch {
    // paint type not supported
  }

  // LCP
  let lcpObserver: PerformanceObserver | null = null
  try {
    lcpObserver = new PerformanceObserver((list) => {
      const entries = list.getEntries()
      const last = entries[entries.length - 1]
      if (last) {
        snapshot.lcp = last.startTime
      }
    })
    lcpObserver.observe({ type: 'largest-contentful-paint', buffered: true } as PerformanceObserverInit)
  } catch {
    // largest-contentful-paint type not supported
  }

  // CLS
  let clsObserver: PerformanceObserver | null = null
  let clsValue = 0
  try {
    clsObserver = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        const ls = entry as unknown as LayoutShiftEntry
        if (!ls.hadRecentInput) {
          clsValue += ls.value
        }
      }
      snapshot.cls = clsValue
    })
    clsObserver.observe({ type: 'layout-shift', buffered: true } as PerformanceObserverInit)
  } catch {
    // layout-shift type not supported
  }

  // FID
  let fidObserver: PerformanceObserver | null = null
  try {
    fidObserver = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        const fi = entry as unknown as FirstInputEntry
        snapshot.fid = fi.processingStart - fi.startTime
      }
    })
    fidObserver.observe({ type: 'first-input', buffered: true } as PerformanceObserverInit)
  } catch {
    // first-input type not supported
  }

  // Expose globally for test/playwright inspection
  ;(window as unknown as Record<string, unknown>).__MASC_WEB_VITALS__ = getWebVitalsSnapshot

  return () => {
    paintObserver?.disconnect()
    lcpObserver?.disconnect()
    clsObserver?.disconnect()
    fidObserver?.disconnect()
    delete (window as unknown as Record<string, unknown>).__MASC_WEB_VITALS__
  }
}
