// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  showToast,
  showActionToast,
  ToastContainer,
  MAX_VISIBLE_TOASTS,
  defaultToastDuration,
  pauseToastTimer,
  resumeToastTimer,
  _testResetToasts,
  _testGetToasts,
} from './toast'

const flushUi = async () => {
  for (let i = 0; i < 4; i++) await Promise.resolve()
}

describe('toast queue semantics', () => {
  beforeEach(() => { _testResetToasts() })
  afterEach(() => { _testResetToasts(); vi.useRealTimers() })

  it('showToast enqueues a single toast with the provided type', () => {
    showToast('first message', 'success')
    const q = _testGetToasts()
    expect(q.length).toBe(1)
    expect(q[0]!.message).toBe('first message')
    expect(q[0]!.type).toBe('success')
  })

  it('toasts are auto-dismissed after the duration', () => {
    vi.useFakeTimers()
    showToast('gone soon', 'success', 2000)
    expect(_testGetToasts().length).toBe(1)
    vi.advanceTimersByTime(2000)
    expect(_testGetToasts().length).toBe(0)
  })

  it('queue caps at MAX_VISIBLE_TOASTS — oldest is evicted when the Nth+1 arrives', () => {
    for (let i = 0; i < MAX_VISIBLE_TOASTS + 2; i++) {
      showToast(`msg ${i}`, 'success', 60_000) // long duration so nothing auto-expires
    }
    const q = _testGetToasts()
    expect(q.length).toBe(MAX_VISIBLE_TOASTS)
    // The two oldest (msg 0 and msg 1) should be gone; the tail should win.
    expect(q[0]!.message).toBe(`msg 2`)
    expect(q[q.length - 1]!.message).toBe(`msg ${MAX_VISIBLE_TOASTS + 1}`)
  })

  it('error toasts land in the queue with type="error"', () => {
    showToast('boom', 'error')
    expect(_testGetToasts()[0]!.type).toBe('error')
  })

  it('showActionToast stores the action on the toast', () => {
    const cb = vi.fn()
    showActionToast('retry this', { label: 'Retry', onClick: cb }, 'error', 60_000)
    const q = _testGetToasts()
    expect(q.length).toBe(1)
    // Public snapshot doesn't expose the action; assert via render instead.
    const container = document.createElement('div')
    document.body.appendChild(container)
    try {
      render(html`<${ToastContainer} />`, container)
      const actionBtn = Array.from(container.querySelectorAll('button'))
        .find(b => b.textContent === 'Retry') as HTMLButtonElement | undefined
      expect(actionBtn).toBeTruthy()
      actionBtn!.click()
      expect(cb).toHaveBeenCalledOnce()
    } finally {
      render(null, container)
      document.body.removeChild(container)
    }
  })
})

describe('ToastContainer rendering', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    _testResetToasts()
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    _testResetToasts()
  })

  it('renders nothing when the queue is empty', () => {
    render(html`<${ToastContainer} />`, container)
    // Empty queue returns null → no outlet markup.
    expect(container.querySelector('[role="status"]')).toBeNull()
    expect(container.querySelector('[role="alert"]')).toBeNull()
  })

  it('success toast renders with role="status" (non-alerting)', async () => {
    showToast('ok', 'success', 60_000)
    render(html`<${ToastContainer} />`, container)
    await flushUi()
    expect(container.querySelector('[role="status"]')).toBeTruthy()
    expect(container.querySelector('[role="alert"]')).toBeNull()
  })

  it('error toast renders with role="alert" (loud, screen-reader interrupting)', async () => {
    showToast('boom', 'error', 60_000)
    render(html`<${ToastContainer} />`, container)
    await flushUi()
    expect(container.querySelector('[role="alert"]')).toBeTruthy()
  })

  it('close (×) button removes only its own toast, not neighbors', async () => {
    showToast('keep', 'success', 60_000)
    showToast('kill', 'error', 60_000)
    render(html`<${ToastContainer} />`, container)
    await flushUi()

    // Find the toast element whose text is "kill" and click its close button
    const errorToast = container.querySelector('[role="alert"]')!
    const closeBtn = errorToast.querySelector('button[aria-label="닫기"]') as HTMLButtonElement
    closeBtn.click()
    await flushUi()

    const remaining = _testGetToasts()
    expect(remaining.length).toBe(1)
    expect(remaining[0]!.message).toBe('keep')
  })
})

describe('defaultToastDuration (pure)', () => {
  it('success dismisses quickly — fire-and-forget confirmation', () => {
    expect(defaultToastDuration('success')).toBe(3000)
  })

  it('warning sits in the middle — attention-worthy but not critical', () => {
    expect(defaultToastDuration('warning')).toBe(5000)
  })

  it('error lingers longest — operator needs time to read + copy', () => {
    // Regression guard: errors are the ones operators actually want
    // to copy (stack trace, id, retry token). Dismissing at 4s has
    // burned users in the past. The explicit > ordering ensures the
    // intent (error > warning > success) survives any future tweak.
    expect(defaultToastDuration('error')).toBe(8000)
    expect(defaultToastDuration('error')).toBeGreaterThan(defaultToastDuration('warning'))
    expect(defaultToastDuration('warning')).toBeGreaterThan(defaultToastDuration('success'))
  })
})

describe('showToast duration fallbacks', () => {
  beforeEach(() => { _testResetToasts(); vi.useFakeTimers() })
  afterEach(() => { _testResetToasts(); vi.useRealTimers() })

  it('error toast defaults to 8000ms, longer than success 3000ms', () => {
    showToast('you failed', 'error')
    vi.advanceTimersByTime(3001) // past success default — error must still be around
    expect(_testGetToasts().length).toBe(1)
    vi.advanceTimersByTime(5000) // now past 8000 total
    expect(_testGetToasts().length).toBe(0)
  })

  it('explicit durationMs still overrides the tiered default', () => {
    // Regression guard: callers that pass durationMs (the existing API)
    // must keep their exact behaviour — we only change the fallback.
    showToast('quick', 'error', 500)
    vi.advanceTimersByTime(501)
    expect(_testGetToasts().length).toBe(0)
  })
})

describe('pauseToastTimer / resumeToastTimer', () => {
  beforeEach(() => { _testResetToasts(); vi.useFakeTimers() })
  afterEach(() => { _testResetToasts(); vi.useRealTimers() })

  it('pause stops the auto-dismiss clock; toast survives past its original deadline', () => {
    showToast('hover me', 'error', 1000)
    const id = _testGetToasts()[0]!.id
    vi.advanceTimersByTime(500)
    pauseToastTimer(id)
    vi.advanceTimersByTime(10_000) // well past 1000ms
    // Toast is still on screen — the timer was paused before it fired.
    expect(_testGetToasts().length).toBe(1)
  })

  it('resume dismisses after the remaining time, not the full duration', () => {
    // Regression guard: a Sonner-style pause-on-hover that restarts
    // the full duration on leave would annoy operators who hovered
    // briefly. Resume must fire at \"remaining\", not at \"duration\".
    showToast('linger then leave', 'error', 1000)
    const id = _testGetToasts()[0]!.id
    vi.advanceTimersByTime(600) // 400ms remaining
    pauseToastTimer(id)
    vi.advanceTimersByTime(5000) // hover lingers, nothing happens
    expect(_testGetToasts().length).toBe(1)
    resumeToastTimer(id)
    vi.advanceTimersByTime(399)
    expect(_testGetToasts().length).toBe(1) // still there, 1ms short
    vi.advanceTimersByTime(2)
    expect(_testGetToasts().length).toBe(0) // dismissed at ~400ms after resume
  })

  it('double-pause is a no-op (Sonner behaviour: child hover does not restart)', () => {
    showToast('nested hover', 'error', 1000)
    const id = _testGetToasts()[0]!.id
    vi.advanceTimersByTime(500) // 500ms remaining
    pauseToastTimer(id)
    // Child element enters → second pause call. Remaining should NOT
    // jump back to the full 1000 or reset elapsed tracking.
    pauseToastTimer(id)
    resumeToastTimer(id)
    vi.advanceTimersByTime(499)
    expect(_testGetToasts().length).toBe(1)
    vi.advanceTimersByTime(2)
    expect(_testGetToasts().length).toBe(0)
  })

  it('resume without prior pause is a no-op (does not double-schedule)', () => {
    showToast('not paused', 'error', 1000)
    const id = _testGetToasts()[0]!.id
    resumeToastTimer(id) // spurious resume — must not schedule a 2nd timer
    vi.advanceTimersByTime(1001)
    expect(_testGetToasts().length).toBe(0) // exactly one dismissal
  })

  it('pause on a dismissed toast id is a no-op (no throw)', () => {
    // Regression guard: a stale mouseenter event after the toast has
    // already auto-dismissed must not throw or create a zombie entry.
    expect(() => pauseToastTimer(999_999)).not.toThrow()
  })
})
