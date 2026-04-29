/**
 * Long Animation Frames (LoAF) observer for the MASC dashboard.
 *
 * This module instruments the browser's long-animation-frame performance
 * entries to detect and report slow main-thread frames.  It is pure
 * observability: no adaptive behavior, no runtime mutation.
 *
 * Supported browsers: Chrome 123+, Edge 123+.  On unsupported browsers
 * the observer constructor throws; we catch and silently disable.
 *
 * See: https://developer.mozilla.org/en-US/docs/Web/API/PerformanceLongAnimationFrameTiming
 */

export interface LoAFScript {
  name: string
  duration: number
  invoker: string
  invokerType: string
  windowAttribution: string
  executionStart: number
}

export interface LoAFEntry extends PerformanceEntry {
  readonly renderStart: number
  readonly styleAndLayoutStart: number
  readonly blockingDuration: number
  readonly firstUIEventTimestamp: number
  readonly scripts: readonly LoAFScript[]
}

export interface PerformanceMonitorOptions {
  /** Maximum number of frames retained in the ring buffer. */
  maxBufferSize?: number
  /** Duration threshold (ms) above which a frame is considered "slow". */
  slowThresholdMs?: number
  /** Optional callback invoked for every slow frame. */
  onSlowFrame?: (entry: LoAFEntry) => void
}

export class PerformanceMonitor {
  private buffer: LoAFEntry[] = []
  private readonly maxBufferSize: number
  private readonly slowThresholdMs: number
  private readonly onSlowFrame?: (entry: LoAFEntry) => void
  private observer?: PerformanceObserver

  constructor(options: PerformanceMonitorOptions = {}) {
    this.maxBufferSize = options.maxBufferSize ?? 100
    this.slowThresholdMs = options.slowThresholdMs ?? 100
    this.onSlowFrame = options.onSlowFrame
  }

  /** Start observing long-animation-frame entries. Idempotent. */
  start(): void {
    if (this.observer) return
    if (typeof PerformanceObserver === 'undefined') return

    try {
      this.observer = new PerformanceObserver((list) => {
        for (const raw of list.getEntries()) {
          const entry = raw as unknown as LoAFEntry
          this.push(entry)
        }
      })

      this.observer.observe({
        type: 'long-animation-frame',
        buffered: true,
      } as PerformanceObserverInit)
    } catch {
      // LoAF unsupported on this browser — silently no-op.
    }
  }

  /** Stop observing and clear the internal observer reference. */
  stop(): void {
    this.observer?.disconnect()
    this.observer = undefined
  }

  /** Return the N most recent frames, oldest first. */
  getRecentFrames(count = 10): readonly LoAFEntry[] {
    return this.buffer.slice(-count)
  }

  /** Average frame duration over the last `windowMs` milliseconds. */
  getAverageDuration(windowMs = 5000): number {
    const cutoff = performance.now() - windowMs
    const recent = this.buffer.filter((e) => e.startTime >= cutoff)
    if (recent.length === 0) return 0
    return recent.reduce((sum, e) => sum + e.duration, 0) / recent.length
  }

  /** Count of slow frames (duration >= threshold) in the buffer. */
  getSlowFrameCount(thresholdMs?: number): number {
    const t = thresholdMs ?? this.slowThresholdMs
    return this.buffer.filter((e) => e.duration >= t).length
  }

  /** Total number of buffered frames. */
  get frameCount(): number {
    return this.buffer.length
  }

  private push(entry: LoAFEntry): void {
    this.buffer.push(entry)
    if (this.buffer.length > this.maxBufferSize) {
      this.buffer.shift()
    }

    if (entry.duration >= this.slowThresholdMs) {
      this.onSlowFrame?.(entry)
      if (import.meta.env?.DEV) {
        const invokers = entry.scripts.map((s) => s.invoker)
        // eslint-disable-next-line no-console
        console.warn(
          `[PerformanceMonitor] Slow frame ${entry.duration.toFixed(1)}ms`,
          invokers
        )
      }
    }
  }
}

/** Default singleton instance. */
export const performanceMonitor = new PerformanceMonitor()
