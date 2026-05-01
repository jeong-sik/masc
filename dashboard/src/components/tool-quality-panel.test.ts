import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ToolQualityResponse } from '../api/dashboard'
import { filterTools, toolMatchesSearch } from './tool-quality-panel'

vi.setConfig({
  testTimeout: 40000,
  hookTimeout: 40000,
})

const payload = {
  generated_at: '2026-04-14T00:00:00Z',
  sampling_mode: 'window_hours',
  sample_limit: null,
  window_hours: 24,
  total: 22,
  success: 21,
  failure: 1,
  success_rate: 95.5,
  by_tool: [],
  by_keeper: [],
  failure_categories: [],
  hourly_trend: [],
}

const payloadWithMissingToolMetrics = {
  ...payload,
  by_tool: [
    {
      name: 'masc_example',
      calls: 3,
      success_pct: 100,
      avg_ms: 42,
    },
  ],
}

function okJson<T>(body: T) {
  return {
    ok: true,
    status: 200,
    statusText: 'OK',
    json: async () => body,
    text: async () => JSON.stringify(body),
  }
}

async function flushUi(): Promise<void> {
  await act(async () => {
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
      await vi.advanceTimersByTimeAsync(0)
    }
  })
}

async function loadPanel(mocks?: {
  fetchToolQuality?: (opts?: { n?: number; windowHours?: number; signal?: AbortSignal }) => Promise<ToolQualityResponse>
}) {
  vi.resetModules()
  if (mocks?.fetchToolQuality) {
    vi.doMock('../api/dashboard', async () => {
      const actual = await vi.importActual<typeof import('../api/dashboard')>('../api/dashboard')
      return {
        ...actual,
        fetchToolQuality: mocks.fetchToolQuality,
      }
    })
  }
  return import('./tool-quality-panel')
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
    vi.clearAllTimers()
    vi.resetModules()
    vi.doUnmock('../api/dashboard')
    vi.useRealTimers()
    if (originalVisibility) {
      Object.defineProperty(document, 'visibilityState', originalVisibility)
    }
  })

  it('auto-refreshes tool quality while visible', async () => {
    const fetchToolQuality = vi.fn().mockResolvedValue(payload)
    const { ToolQualityPanel } = await loadPanel({ fetchToolQuality })

    await act(async () => {
      render(html`<${ToolQualityPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchToolQuality).toHaveBeenCalledTimes(1)
    expect(container.textContent).toContain('Auto-refresh 30s')
    expect(container.textContent).toContain('95.5%')
    expect(container.textContent).toContain('최근 24시간 기준 집계')
    expect(container.textContent).toContain('Window Calls')

    vi.advanceTimersByTime(30_000)
    await flushUi()

    expect(fetchToolQuality).toHaveBeenCalledTimes(2)
  })

  it('normalizes missing tool metric fields before rendering', async () => {
    const fetchMock = vi.fn().mockResolvedValue(okJson(payloadWithMissingToolMetrics))
    vi.stubGlobal('fetch', fetchMock)
    const { ToolQualityPanel } = await import('./tool-quality-panel')

    await act(async () => {
      render(html`<${ToolQualityPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('m:example')
    expect(container.textContent).toContain('0.0k')
    expect(container.textContent).not.toContain('오류:')
  })

  it('replaces a stale in-flight request with the newest refresh', async () => {
    const fetchMock = vi.fn()
      .mockImplementationOnce((_url: string, init?: RequestInit) => new Promise((_resolve, reject) => {
        const signal = init?.signal as AbortSignal | undefined
        signal?.addEventListener('abort', () => {
          reject(new DOMException('replaced by newer refresh', 'AbortError'))
        })
      }))
      .mockResolvedValueOnce(okJson(payload))
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

  it('refreshes again when the refresh button is clicked', async () => {
    const fetchMock = vi.fn().mockResolvedValue(okJson(payload))
    vi.stubGlobal('fetch', fetchMock)
    const { ToolQualityPanel } = await import('./tool-quality-panel')

    await act(async () => {
      render(html`<${ToolQualityPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const button = container.querySelector('button[aria-label="도구 품질 새로고침"]')
    expect(button).not.toBeNull()

    await act(async () => {
      button?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchMock).toHaveBeenCalledTimes(2)
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

    vi.advanceTimersByTime(30_000)
    await flushUi()

    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('aborts an in-flight request when the panel unmounts', async () => {
    let activeSignal: AbortSignal | undefined
    const fetchMock = vi.fn().mockImplementation((_url: string, init?: RequestInit) => new Promise((_resolve, reject) => {
      activeSignal = init?.signal as AbortSignal | undefined
      activeSignal?.addEventListener('abort', () => {
        reject(new DOMException('panel unmounted', 'AbortError'))
      }, { once: true })
    }))
    vi.stubGlobal('fetch', fetchMock)
    const { ToolQualityPanel } = await import('./tool-quality-panel')

    await act(async () => {
      render(html`<${ToolQualityPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(activeSignal?.aborted).toBe(false)
    expect(container.textContent).toContain('도구 품질 불러오는 중')

    await act(async () => {
      render(null, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(activeSignal?.aborted).toBe(true)
  })

  it('reports timeout durations from the shared API helper', async () => {
    const fetchMock = vi.fn().mockImplementation((_url: string, init?: RequestInit) => new Promise((_resolve, reject) => {
      const signal = init?.signal as AbortSignal | undefined
      signal?.addEventListener('abort', () => {
        reject(new DOMException('request timed out', 'AbortError'))
      }, { once: true })
    }))
    vi.stubGlobal('fetch', fetchMock)
    const { ToolQualityPanel } = await import('./tool-quality-panel')

    await act(async () => {
      render(html`<${ToolQualityPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => 'hidden',
    })

    vi.advanceTimersByTime(35_000)
    await flushUi()

    expect(container.textContent).toContain('request timeout (35s)')
  })
})

describe('toolMatchesSearch', () => {
  const tool = { name: 'keeper_task_claim' }

  it('returns true for empty query (no filter)', () => {
    expect(toolMatchesSearch(tool, '')).toBe(true)
    expect(toolMatchesSearch(tool, '   ')).toBe(true)
  })

  it('matches substring in the middle of the name', () => {
    expect(toolMatchesSearch(tool, 'task')).toBe(true)
    expect(toolMatchesSearch(tool, 'r_t')).toBe(true)
  })

  it('matches prefix and suffix', () => {
    expect(toolMatchesSearch(tool, 'keeper')).toBe(true)
    expect(toolMatchesSearch(tool, 'claim')).toBe(true)
  })

  it('is case-insensitive', () => {
    expect(toolMatchesSearch(tool, 'TASK')).toBe(true)
    expect(toolMatchesSearch(tool, 'Keeper')).toBe(true)
    expect(toolMatchesSearch({ name: 'MASC_ToolName' }, 'toolname')).toBe(true)
  })

  it('ignores surrounding whitespace in the query', () => {
    expect(toolMatchesSearch(tool, '  task  ')).toBe(true)
  })

  it('returns false for non-matching substring', () => {
    expect(toolMatchesSearch(tool, 'xyz')).toBe(false)
    expect(toolMatchesSearch(tool, 'cascade')).toBe(false)
  })
})

describe('filterTools', () => {
  const tools = [
    { name: 'keeper_task_claim' },
    { name: 'keeper_task_done' },
    { name: 'masc_broadcast' },
    { name: 'cascade_route' },
    { name: 'read_file' },
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterTools(tools, '')).toBe(tools)
    expect(filterTools(tools, '   ')).toBe(tools)
  })

  it('returns only tools whose name contains the query', () => {
    const result = filterTools(tools, 'task')
    expect(result.map(t => t.name)).toEqual([
      'keeper_task_claim',
      'keeper_task_done',
    ])
  })

  it('is case-insensitive', () => {
    const result = filterTools(tools, 'KEEPER')
    expect(result).toHaveLength(2)
    expect(result.every(t => t.name.includes('keeper'))).toBe(true)
  })

  it('returns an empty array when nothing matches', () => {
    expect(filterTools(tools, 'zzz')).toEqual([])
  })

  it('does not mutate the source array', () => {
    const snapshot = tools.map(t => t.name)
    filterTools(tools, 'task')
    expect(tools.map(t => t.name)).toEqual(snapshot)
  })

  it('preserves extra fields on the input objects', () => {
    const rich = [
      { name: 'alpha', calls: 10 },
      { name: 'beta', calls: 20 },
    ]
    const result = filterTools(rich, 'alpha')
    expect(result).toEqual([{ name: 'alpha', calls: 10 }])
  })
})
