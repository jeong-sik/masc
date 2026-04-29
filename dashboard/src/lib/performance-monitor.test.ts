import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { PerformanceMonitor, type LoAFEntry } from './performance-monitor'

describe('PerformanceMonitor', () => {
  let monitor!: PerformanceMonitor

  beforeEach(() => {
    monitor = new PerformanceMonitor({ maxBufferSize: 5, slowThresholdMs: 50 })
  })

  afterEach(() => {
    monitor.stop()
  })

  it('buffers frames up to maxBufferSize', () => {
    const base = performance.now()
    for (let i = 0; i < 10; i++) {
      monitor['push'](makeEntry(base + i, 10))
    }
    expect(monitor.frameCount).toBe(5)
    expect(monitor.getRecentFrames(1)[0]!.startTime).toBe(base + 9)
  })

  it('computes average duration over a window', () => {
    const now = performance.now()
    monitor['push'](makeEntry(now - 1000, 20))
    monitor['push'](makeEntry(now - 500, 40))
    monitor['push'](makeEntry(now - 100, 60))

    expect(monitor.getAverageDuration(2000)).toBeCloseTo(40, 1)
    expect(monitor.getAverageDuration(300)).toBeCloseTo(60, 1)
    expect(monitor.getAverageDuration(50)).toBe(0)
  })

  it('counts slow frames correctly', () => {
    monitor['push'](makeEntry(0, 30))
    monitor['push'](makeEntry(1, 60))
    monitor['push'](makeEntry(2, 50))
    monitor['push'](makeEntry(3, 90))

    expect(monitor.getSlowFrameCount()).toBe(3)
    expect(monitor.getSlowFrameCount(40)).toBe(3)
  })

  it('invokes onSlowFrame callback for slow frames', () => {
    const onSlowFrame = vi.fn()
    monitor = new PerformanceMonitor({
      maxBufferSize: 5,
      slowThresholdMs: 50,
      onSlowFrame,
    })

    monitor['push'](makeEntry(0, 30))
    expect(onSlowFrame).not.toHaveBeenCalled()

    monitor['push'](makeEntry(1, 70))
    expect(onSlowFrame).toHaveBeenCalledTimes(1)
    expect(onSlowFrame).toHaveBeenCalledWith(
      expect.objectContaining({ duration: 70 })
    )
  })

  it('is idempotent on start()', () => {
    // In happy-dom PerformanceObserver may not exist or throw.
    // We just verify no exception and idempotency.
    monitor.start()
    const obs = monitor['observer']
    monitor.start()
    expect(monitor['observer']).toBe(obs)
  })

  it('buffers long tasks up to maxBufferSize', () => {
    const lt = { name: 'longtask', duration: 120, startTime: 0 } as PerformanceEntry
    for (let i = 0; i < 10; i++) {
      monitor['longTaskBuffer'].push(lt)
      if (monitor['longTaskBuffer'].length > monitor['maxBufferSize']) {
        monitor['longTaskBuffer'].shift()
      }
    }
    expect(monitor.longTaskCount).toBe(5)
    expect(monitor.getRecentLongTasks(1)[0]!).toBe(lt)
  })

  it('returns FPS metrics from history', () => {
    monitor['fpsHistory'].push(30, 60, 45)
    expect(monitor.getCurrentFps()).toBe(45)
    expect(monitor.getAverageFps(3)).toBeCloseTo(45, 1)
    expect(monitor.getAverageFps(10)).toBeCloseTo(45, 1)
    expect(monitor.getFpsHistory()).toEqual([30, 60, 45])
  })

  it('returns zero for empty FPS history', () => {
    expect(monitor.getCurrentFps()).toBe(0)
    expect(monitor.getAverageFps()).toBe(0)
    expect(monitor.getFpsHistory()).toEqual([])
  })
})

function makeEntry(startTime: number, duration: number): LoAFEntry {
  return {
    name: 'long-animation-frame',
    entryType: 'long-animation-frame',
    startTime,
    duration,
    renderStart: startTime,
    styleAndLayoutStart: startTime,
    blockingDuration: duration,
    firstUIEventTimestamp: startTime,
    scripts: [],
    toJSON() {
      return this
    },
  } as unknown as LoAFEntry
}
