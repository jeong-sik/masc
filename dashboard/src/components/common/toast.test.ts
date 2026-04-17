// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  showToast,
  showActionToast,
  ToastContainer,
  MAX_VISIBLE_TOASTS,
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
