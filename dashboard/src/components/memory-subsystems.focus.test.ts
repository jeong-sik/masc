// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { MemorySubsystemsResponse } from '../api/dashboard'
import { MemorySubsystems } from './memory-subsystems'

const baseResponse: MemorySubsystemsResponse = {
  generated_at: '2026-05-13T00:00:00Z',
  hebbian: {
    synapses: [],
    last_consolidation: 0,
  },
  episodes: {
    total: 1,
    filtered: 1,
    shown: 1,
    limit: 100,
    items: [
      {
        id: 'episode-1',
        timestamp: 1,
        participants: ['keeper-alpha'],
        event_type: 'task_done',
        summary: 'Finished a task',
        outcome: 'success',
        learnings: ['ship focused changes'],
        context: {},
      },
    ],
  },
  delegation_requests: {
    total: 1,
    shown: 1,
    limit: 100,
    index_path: '<base-path>/.masc/delegation-requests/index.jsonl',
    items: [
      {
        id: 'delegation-rendering-review',
        requester: 'keeper-alpha',
        topic: 'Review non-dashboard rendering',
        promotion_state: 'candidate',
        dir: '<base-path>/.masc/delegation-requests/delegation-rendering-review',
        json_path: '<base-path>/.masc/delegation-requests/delegation-rendering-review/request.json',
        task_seed_md_path: '<base-path>/.masc/delegation-requests/delegation-rendering-review/TASK_SEED.md',
        created_at: 1,
      },
    ],
    error: null,
  },
  filters: {
    keepers: ['keeper-alpha'],
    outcomes: ['success'],
  },
}

function jsonResponse(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
}

describe('MemorySubsystems focus targets', () => {
  let container: HTMLDivElement
  let originalScrollIntoView: typeof HTMLElement.prototype.scrollIntoView | undefined
  let originalFocus: typeof HTMLElement.prototype.focus | undefined
  let scrollIntoViewMock: ReturnType<typeof vi.fn>
  let focusMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    originalScrollIntoView = HTMLElement.prototype.scrollIntoView
    originalFocus = HTMLElement.prototype.focus
    scrollIntoViewMock = vi.fn()
    focusMock = vi.fn()
    Object.defineProperty(HTMLElement.prototype, 'scrollIntoView', {
      configurable: true,
      value: scrollIntoViewMock,
    })
    Object.defineProperty(HTMLElement.prototype, 'focus', {
      configurable: true,
      value: focusMock,
    })
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    if (originalScrollIntoView) {
      Object.defineProperty(HTMLElement.prototype, 'scrollIntoView', {
        configurable: true,
        value: originalScrollIntoView,
      })
    } else {
      Reflect.deleteProperty(HTMLElement.prototype, 'scrollIntoView')
    }
    if (originalFocus) {
      Object.defineProperty(HTMLElement.prototype, 'focus', {
        configurable: true,
        value: originalFocus,
      })
    } else {
      Reflect.deleteProperty(HTMLElement.prototype, 'focus')
    }
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('renders delegation requests from the memory subsystem payload', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(baseResponse))
    vi.stubGlobal('fetch', fetchMock)

    render(html`<${MemorySubsystems} />`, container)

    await vi.waitFor(() => {
      expect(container.textContent).toContain('delegation-rendering-review')
      expect(container.textContent).toContain('Review non-dashboard rendering')
      expect(container.textContent).toContain('<base-path>/.masc/delegation-requests/delegation-rendering-review/TASK_SEED.md')
    })
    expect(container.querySelector('[data-testid="delegation-requests"]')).not.toBeNull()
  })

  it('renders delegation request empty and error states', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse({
        ...baseResponse,
        delegation_requests: {
          total: 0,
          shown: 0,
          limit: 100,
          index_path: '<base-path>/.masc/delegation-requests/index.jsonl',
          items: [],
          error: 'delegation request index read failed',
        },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    render(html`<${MemorySubsystems} />`, container)

    await vi.waitFor(() => {
      expect(container.querySelector('[data-testid="delegation-requests"]')).not.toBeNull()
      expect(container.querySelector('[role="alert"]')?.textContent).toContain(
        'delegation request index read failed',
      )
      expect(container.textContent).toContain('delegation request 없음')
      expect(container.textContent).toContain('total 0 · shown 0')
    })
  })

  it('focuses the episodes section for episodes focus', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(baseResponse))
    vi.stubGlobal('fetch', fetchMock)

    render(html`<${MemorySubsystems} focus=${'episodes'} />`, container)

    await vi.waitFor(() => {
      expect(fetchMock).toHaveBeenCalled()
    })
    await vi.waitFor(() => {
      expect(container.textContent).toContain('Finished a task')
    })

    const target = container.querySelector('[data-memory-focus-target="episodes"]')
    expect(target).not.toBeNull()
    await vi.waitFor(() => {
      expect(focusMock.mock.contexts).toContain(target)
      expect(scrollIntoViewMock.mock.contexts).toContain(target)
    })
  })

  it('does not scroll or focus the episodes section without a focus target', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(baseResponse))
    vi.stubGlobal('fetch', fetchMock)

    render(html`<${MemorySubsystems} />`, container)

    await vi.waitFor(() => {
      expect(container.textContent).toContain('Finished a task')
    })

    expect(scrollIntoViewMock).not.toHaveBeenCalled()
    expect(focusMock).not.toHaveBeenCalled()
  })
})
