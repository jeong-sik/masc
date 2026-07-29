// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { MemorySubsystemsResponse } from '../api/dashboard'
import { MemorySubsystems } from './memory-subsystems'

const baseResponse: MemorySubsystemsResponse = {
  generated_at: '2026-05-13T00:00:00Z',
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
}

function jsonResponse(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
}

describe('MemorySubsystems delegation requests', () => {
  let container: HTMLDivElement

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('renders delegation requests from the memory subsystem payload', async () => {
    container = document.createElement('div')
    document.body.appendChild(container)
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
    container = document.createElement('div')
    document.body.appendChild(container)
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
})
