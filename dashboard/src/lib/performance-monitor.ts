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

interface PerformanceMonitorOptions {
  /** Maximum number of frames retained in the ring buffer. */
  maxBufferSize?: number
  /** Duration threshold (ms) above which a frame is considered "slow". */
  slowThresholdMs?: number
  /** Optional callback invoked for every slow frame. */
  onSlowFrame?: (entry: LoAFEntry) => void
  /** Enable Long Tasks API observer (default true). */
  enableLongTasks?: boolean
  /** Enable FPS monitoring via requestAnimationFrame (default true). */
  enableFps?: boolean
}

export class PerformanceMonitor {
  private buffer: LoAFEntry[] = []
  private readonly maxBufferSize: number
  private readonly slowThresholdMs: number
  private readonly onSlowFrame?: (entry: LoAFEntry) => void
  private readonly enableLongTasks: boolean
  private readonly enableFps: boolean
  private observer?: PerformanceObserver
  private longTaskObserver?: PerformanceObserver
  private longTaskBuffer: PerformanceEntry[] = []
  private fpsHistory: number[] = []
  private fpsRafId?: number
  private fpsLastTime?: number
  private fpsFrameCount = 0
  private running = false

  constructor(options: PerformanceMonitorOptions = {}) {
    this.maxBufferSize = options.maxBufferSize ?? 100
    this.slowThresholdMs = options.slowThresholdMs ?? 100
    this.onSlowFrame = options.onSlowFrame
    this.enableLongTasks = options.enableLongTasks ?? true
    this.enableFps = options.enableFps ?? true
  }

  /** Start observing performance entries. Idempotent. */
  start(): void {
    if (this.running) return
    this.running = true
    this.startLoAF()
    if (this.enableLongTasks) this.startLongTasks()
    if (this.enableFps) this.startFps()
  }

  private startLoAF(): void {
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

  private startLongTasks(): void {
    if (this.longTaskObserver) return
    if (typeof PerformanceObserver === 'undefined') return

    try {
      this.longTaskObserver = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          this.longTaskBuffer.push(entry)
          if (this.longTaskBuffer.length > this.maxBufferSize) {
            this.longTaskBuffer.shift()
          }
        }
      })
      this.longTaskObserver.observe({ entryTypes: ['longtask'] } as PerformanceObserverInit)
    } catch {
      // Long Tasks API unsupported — silently no-op.
    }
  }

  private startFps(): void {
    if (this.fpsRafId) return
    if (typeof requestAnimationFrame === 'undefined') return

    const tick = (time: number) => {
      if (!this.running) return
      if (this.fpsLastTime == null) {
        this.fpsLastTime = time
      }
      const elapsed = time - this.fpsLastTime
      this.fpsFrameCount++
      if (elapsed >= 1000) {
        const fps = Math.round((this.fpsFrameCount * 1000) / elapsed)
        this.fpsHistory.push(fps)
        if (this.fpsHistory.length > this.maxBufferSize) {
          this.fpsHistory.shift()
        }
        this.fpsFrameCount = 0
        this.fpsLastTime = time
      }
      this.fpsRafId = requestAnimationFrame(tick)
    }
    this.fpsRafId = requestAnimationFrame(tick)
  }

  /** Stop observing and clear internal observers. */
  stop(): void {
    this.running = false
    this.observer?.disconnect()
    this.observer = undefined
    this.longTaskObserver?.disconnect()
    this.longTaskObserver = undefined
    if (this.fpsRafId) {
      cancelAnimationFrame(this.fpsRafId)
      this.fpsRafId = undefined
    }
    this.fpsLastTime = undefined
    this.fpsFrameCount = 0
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

  /** Return the N most recent long-task entries, oldest first. */
  getRecentLongTasks(count = 10): readonly PerformanceEntry[] {
    return this.longTaskBuffer.slice(-count)
  }

  /** Total number of buffered long tasks. */
  get longTaskCount(): number {
    return this.longTaskBuffer.length
  }

  /** Most recent FPS reading, or 0 if none yet. */
  getCurrentFps(): number {
    if (this.fpsHistory.length === 0) return 0
    return this.fpsHistory[this.fpsHistory.length - 1]!
  }

  /** Average FPS over the last `window` readings. */
  getAverageFps(window = 10): number {
    const recent = this.fpsHistory.slice(-window)
    if (recent.length === 0) return 0
    return recent.reduce((sum, fps) => sum + fps, 0) / recent.length
  }

  /** Full FPS history (copy), oldest first. */
  getFpsHistory(): readonly number[] {
    return [...this.fpsHistory]
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
