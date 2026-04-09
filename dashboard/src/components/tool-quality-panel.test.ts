import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const payload = {
  total: 22,
  success: 21,
  failure: 1,
  success_rate: 95.5,
  by_tool: [],
  by_keeper: [],
  failure_categories: [],
  hourly_trend: [],
}

async function flushUi(): Promise<void> {
  await act(async () => {
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
      await vi.advanceTimersByTimeAsync(0)
    }
  })
}

describe('ToolQualityPanel', () => {
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
    vi.unstubAllGlobals()
    vi.clearAllMocks()
    vi.resetModules()
    vi.useRealTimers()
    if (originalVisibility) {
      Object.defineProperty(document, 'visibilityState', originalVisibility)
    }
  })

  it('auto-refreshes tool quality while visible', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => payload,
    })
    vi.stubGlobal('fetch', fetchMock)
    const { ToolQualityPanel } = await import('./tool-quality-panel')

    await act(async () => {
      render(html`<${ToolQualityPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(container.textContent).toContain('30초 자동 갱신')
    expect(container.textContent).toContain('95.5%')

    await vi.advanceTimersByTimeAsync(30_000)
    await flushUi()

    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('replaces a stale in-flight request with the newest refresh', async () => {
    const fetchMock = vi.fn()
      .mockImplementationOnce((_url: string, init?: RequestInit) => new Promise((_resolve, reject) => {
        const signal = init?.signal as AbortSignal | undefined
        signal?.addEventListener('abort', () => {
          reject(new DOMException('replaced by newer refresh', 'AbortError'))
        })
      }))
      .mockResolvedValueOnce({
        ok: true,
        json: async () => payload,
      })
    vi.stubGlobal('fetch', fetchMock)
    const { ToolQualityPanel, refreshToolQuality } = await import('./tool-quality-panel')

    await act(async () => {
      render(html`<${ToolQualityPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('도구 품질 불러오는 중')

    await act(async () => {
      await refreshToolQuality()
    })
    await flushUi()

    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(container.textContent).toContain('95.5%')
    expect(container.textContent).not.toContain('오류:')
  })

  it('stops auto-refresh after the panel unmounts', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => payload,
    })
    vi.stubGlobal('fetch', fetchMock)
    const { ToolQualityPanel } = await import('./tool-quality-panel')

    await act(async () => {
      render(html`<${ToolQualityPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchMock).toHaveBeenCalledTimes(1)

    await act(async () => {
      render(null, container)
      await Promise.resolve()
    })

    await vi.advanceTimersByTimeAsync(30_000)
    await flushUi()

    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})
