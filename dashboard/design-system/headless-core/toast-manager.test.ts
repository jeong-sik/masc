// Pure TS unit tests for ToastManager. No DOM, no Preact runtime.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  createToastManager,
  SEVERITY_DEFAULT_DURATION_MS,
  SEVERITY_PRIORITY,
  SEVERITY_TO_ARIA_LIVE,
  SEVERITY_TO_ROLE,
} from './toast-manager'

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(new Date('2026-04-29T00:00:00Z'))
})
afterEach(() => {
  vi.useRealTimers()
})

describe('createToastManager — notify and visible', () => {
  it('first notify becomes visible immediately', () => {
    const m = createToastManager()
    const id = m.notify({ severity: 'info', message: 'hello' })
    const queue = m.getQueue()
    expect(queue).toHaveLength(1)
    expect(queue[0]!.id).toBe(id)
    expect(queue[0]!.state).toBe('visible')
  })

  it('auto-dismiss after duration', () => {
    const m = createToastManager()
    m.notify({ severity: 'info', message: 'hi', duration: 1000 })
    expect(m.getQueue()[0]!.state).toBe('visible')
    vi.advanceTimersByTime(999)
    expect(m.getQueue()[0]!.state).toBe('visible')
    vi.advanceTimersByTime(1)
    expect(m.getQueue()[0]!.state).toBe('dismissed')
  })

  it('sticky duration: 0 never auto-dismisses', () => {
    const m = createToastManager()
    m.notify({ severity: 'error', message: 'oops' })
    vi.advanceTimersByTime(60_000)
    expect(m.getQueue()[0]!.state).toBe('visible')
  })
})

describe('createToastManager — dedup', () => {
  it('replaces in place and resets timer', () => {
    const m = createToastManager()
    const id1 = m.notify({ severity: 'info', message: 'one', dedupKey: 'k', duration: 1000 })
    vi.advanceTimersByTime(800)
    const id2 = m.notify({ severity: 'info', message: 'two', dedupKey: 'k', duration: 1000 })
    expect(id1).toBe(id2)
    const queue = m.getQueue()
    expect(queue).toHaveLength(1)
    expect(queue[0]!.message).toBe('two')
    // Timer reset; original 800ms elapsed shouldn't matter.
    vi.advanceTimersByTime(900)
    expect(m.getQueue()[0]!.state).toBe('visible')
    vi.advanceTimersByTime(100)
    expect(m.getQueue()[0]!.state).toBe('dismissed')
  })
})

describe('createToastManager — priority and ordering', () => {
  it('error renders before info regardless of arrival order', () => {
    const m = createToastManager()
    m.notify({ severity: 'info', message: 'i' })
    m.notify({ severity: 'error', message: 'e' })
    const queue = m.getQueue()
    expect(queue[0]!.severity).toBe('error')
    expect(queue[1]!.severity).toBe('info')
  })

  it('FIFO at same priority', () => {
    const m = createToastManager()
    m.notify({ severity: 'info', message: 'first' })
    vi.advanceTimersByTime(10)
    m.notify({ severity: 'info', message: 'second' })
    const queue = m.getQueue()
    expect(queue[0]!.message).toBe('first')
    expect(queue[1]!.message).toBe('second')
  })
})

describe('createToastManager — max visible cap', () => {
  it('6th notify queues; first dismissal promotes queue head', () => {
    const m = createToastManager({ maxVisible: 5 })
    for (let i = 0; i < 5; i += 1) {
      m.notify({ severity: 'info', message: `v${i}`, duration: 1000 })
      vi.advanceTimersByTime(1)
    }
    const sixthId = m.notify({ severity: 'info', message: 'queued', duration: 1000 })
    let queue = m.getQueue()
    const sixth = queue.find((t) => t.id === sixthId)!
    expect(sixth.state).toBe('queued')
    // Dismiss one visible → 6th promotes
    m.dismiss(queue[0]!.id)
    queue = m.getQueue()
    const promoted = queue.find((t) => t.id === sixthId)!
    expect(promoted.state).toBe('visible')
  })
})

describe('createToastManager — error preempts low-priority', () => {
  it('error arriving when 5 info are visible preempts the oldest info', () => {
    const m = createToastManager({ maxVisible: 5 })
    const ids: string[] = []
    for (let i = 0; i < 5; i += 1) {
      ids.push(m.notify({ severity: 'info', message: `i${i}`, duration: 5000 }))
      vi.advanceTimersByTime(1)
    }
    // All 5 visible
    for (const id of ids) {
      expect(m.getQueue().find((t) => t.id === id)!.state).toBe('visible')
    }
    m.notify({ severity: 'error', message: 'critical' })
    // Oldest info should have been preempted (state=dismissed).
    const queue = m.getQueue()
    const errorEntry = queue.find((t) => t.severity === 'error')!
    expect(errorEntry.state).toBe('visible')
    // First info should now be dismissed.
    expect(queue.find((t) => t.id === ids[0])!.state).toBe('dismissed')
  })

  it('error does NOT preempt another error', () => {
    const m = createToastManager({ maxVisible: 2 })
    const id1 = m.notify({ severity: 'error', message: 'first' })
    const id2 = m.notify({ severity: 'error', message: 'second' })
    expect(m.getQueue().find((t) => t.id === id1)!.state).toBe('visible')
    expect(m.getQueue().find((t) => t.id === id2)!.state).toBe('visible')
    const id3 = m.notify({ severity: 'error', message: 'third' })
    // Third has same priority as the others; cannot preempt.
    expect(m.getQueue().find((t) => t.id === id3)!.state).toBe('queued')
  })
})

describe('createToastManager — pause / resume', () => {
  it('pause + resume preserves elapsed time', () => {
    const m = createToastManager()
    const id = m.notify({ severity: 'info', message: 'p', duration: 1000 })
    vi.advanceTimersByTime(300)
    m.pause(id)
    vi.advanceTimersByTime(5_000) // long pause
    expect(m.getQueue().find((t) => t.id === id)!.state).toBe('visible')
    m.resume(id)
    vi.advanceTimersByTime(699)
    expect(m.getQueue().find((t) => t.id === id)!.state).toBe('visible')
    vi.advanceTimersByTime(1)
    expect(m.getQueue().find((t) => t.id === id)!.state).toBe('dismissed')
  })

  it('pauseAll / resumeAll affect every visible toast', () => {
    const m = createToastManager({ maxVisible: 3 })
    m.notify({ severity: 'info', message: '1', duration: 1000 })
    m.notify({ severity: 'info', message: '2', duration: 1000 })
    vi.advanceTimersByTime(500)
    m.pauseAll()
    vi.advanceTimersByTime(5000)
    for (const t of m.getQueue()) {
      expect(t.state).toBe('visible')
    }
    m.resumeAll()
    vi.advanceTimersByTime(499)
    for (const t of m.getQueue()) {
      expect(t.state).toBe('visible')
    }
    vi.advanceTimersByTime(1)
    for (const t of m.getQueue()) {
      expect(t.state).toBe('dismissed')
    }
  })
})

describe('createToastManager — action button', () => {
  it('action click dismisses the toast (consumer responsibility — manager exposes action)', () => {
    const onClick = vi.fn()
    const m = createToastManager()
    const id = m.notify({
      severity: 'info',
      message: 'undo me',
      action: { label: 'Undo', onClick },
    })
    const t = m.getQueue().find((tt) => tt.id === id)!
    expect(t.action?.label).toBe('Undo')
    // Consumer fires action click then explicit dismiss:
    t.action!.onClick()
    m.dismiss(id)
    expect(onClick).toHaveBeenCalledOnce()
    expect(m.getQueue().find((tt) => tt.id === id)!.state).toBe('dismissed')
  })
})

describe('createToastManager — dismissAll', () => {
  it('flips every visible/queued to dismissed', () => {
    const m = createToastManager({ maxVisible: 2 })
    m.notify({ severity: 'info', message: '1' })
    m.notify({ severity: 'info', message: '2' })
    m.notify({ severity: 'info', message: '3' }) // queued
    m.dismissAll()
    for (const t of m.getQueue()) {
      expect(t.state).toBe('dismissed')
    }
  })
})

describe('createToastManager — severity static maps', () => {
  it('SEVERITY_PRIORITY orders error > warning > success > info', () => {
    expect(SEVERITY_PRIORITY.error).toBeGreaterThan(SEVERITY_PRIORITY.warning)
    expect(SEVERITY_PRIORITY.warning).toBeGreaterThan(SEVERITY_PRIORITY.success)
    expect(SEVERITY_PRIORITY.success).toBeGreaterThan(SEVERITY_PRIORITY.info)
  })

  it('default durations match RFC table', () => {
    expect(SEVERITY_DEFAULT_DURATION_MS.error).toBe(0)
    expect(SEVERITY_DEFAULT_DURATION_MS.warning).toBe(8000)
    expect(SEVERITY_DEFAULT_DURATION_MS.success).toBe(5000)
    expect(SEVERITY_DEFAULT_DURATION_MS.info).toBe(5000)
  })

  it('role mapping: error → alert, others → status', () => {
    expect(SEVERITY_TO_ROLE.error).toBe('alert')
    expect(SEVERITY_TO_ROLE.warning).toBe('status')
    expect(SEVERITY_TO_ROLE.success).toBe('status')
    expect(SEVERITY_TO_ROLE.info).toBe('status')
  })

  it('aria-live mapping: error → assertive, others → polite', () => {
    expect(SEVERITY_TO_ARIA_LIVE.error).toBe('assertive')
    expect(SEVERITY_TO_ARIA_LIVE.warning).toBe('polite')
    expect(SEVERITY_TO_ARIA_LIVE.success).toBe('polite')
    expect(SEVERITY_TO_ARIA_LIVE.info).toBe('polite')
  })
})

describe('createToastManager — subscribe / unsubscribe', () => {
  it('subscriber fires on every state change', () => {
    const m = createToastManager()
    let calls = 0
    const dispose = m.subscribe(() => {
      calls += 1
    })
    m.notify({ severity: 'info', message: 'a' })
    expect(calls).toBeGreaterThan(0)
    dispose()
    const before = calls
    m.notify({ severity: 'info', message: 'b' })
    expect(calls).toBe(before)
  })
})
