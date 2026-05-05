import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

async function flushUi(): Promise<void> {
  await act(async () => {
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
      await vi.advanceTimersByTimeAsync(0)
    }
  })
}

async function loadMonitor(get: (path: string, opts?: { signal?: AbortSignal }) => Promise<unknown>) {
  vi.resetModules()
  vi.doMock('../api/core', () => ({ get }))
  return import('./governance-monitor')
}

describe('GovernanceMonitor', () => {
  let container: HTMLDivElement
  const originalVisibility = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState')

  beforeEach(() => {
    vi.useFakeTimers()
    container = document.createElement('div')
    document.body.appendChild(container)
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => 'visible',
    })
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllTimers()
    vi.clearAllMocks()
    vi.resetModules()
    vi.doUnmock('../api/core')
    vi.useRealTimers()
    if (originalVisibility) {
      Object.defineProperty(document, 'visibilityState', originalVisibility)
    }
  })

  it('auto-refreshes governance metrics while visible', async () => {
    const get = vi.fn().mockResolvedValue({
      generated_at: '2026-04-21T00:00:00Z',
      window_minutes: 60,
      tool_rejections: [],
      approval_queue: {
        depth: 0,
        p50_wait_sec: null,
        p95_wait_sec: null,
        oldest_pending_sec: null,
      },
    })
    const { GovernanceMonitor } = await loadMonitor(get)

    await act(async () => {
      render(html`<${GovernanceMonitor} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(get).toHaveBeenCalledTimes(1)
    expect(container.textContent).toContain('Auto-refresh 30s')

    await vi.advanceTimersByTimeAsync(30_000)
    await flushUi()

    expect(get).toHaveBeenCalledTimes(2)
  })
})

