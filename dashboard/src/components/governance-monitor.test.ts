import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { filterToolRejections, type ToolRejection } from './governance-monitor'

function makeRejection(overrides: Partial<ToolRejection> = {}): ToolRejection {
  return {
    tool: 'Bash',
    reason: 'permission_denied',
    count: 1,
    ...overrides,
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

describe('filterToolRejections', () => {
  const rows: ToolRejection[] = [
    makeRejection({ tool: 'Bash', reason: 'permission_denied', count: 12 }),
    makeRejection({ tool: 'WebFetch', reason: 'network_unreachable', count: 3 }),
    makeRejection({ tool: 'Read', reason: 'path_outside_workspace', count: 7 }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterToolRejections(rows, '')).toBe(rows)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterToolRejections(rows, '   ')).toBe(rows)
  })

  it('matches by tool substring (case-insensitive)', () => {
    const result = filterToolRejections(rows, 'BASH')
    expect(result).toHaveLength(1)
    expect(result[0]?.tool).toBe('Bash')
  })

  it('matches by reason substring (case-insensitive)', () => {
    const result = filterToolRejections(rows, 'PERMISSION')
    expect(result.map(r => r.tool)).toEqual(['Bash'])
  })

  it('trims query before matching', () => {
    expect(filterToolRejections(rows, '  webfetch  ')).toHaveLength(1)
  })

  it('returns empty when no field matches', () => {
    expect(filterToolRejections(rows, 'nonexistent-token')).toHaveLength(0)
  })

  it('matches across both fields in a single query', () => {
    // "e" appears in WebFetch/network_unreachable, Read/path_outside_workspace, Bash/permission_denied
    const result = filterToolRejections(rows, 'workspace')
    expect(result.map(r => r.tool)).toEqual(['Read'])
  })

  it('does not mutate the input array', () => {
    const copy = rows.slice()
    filterToolRejections(rows, 'bash')
    expect(rows).toEqual(copy)
  })
})
