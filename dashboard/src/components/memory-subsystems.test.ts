// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { MemorySubsystemsResponse, MemorySubsystemsSynapse } from '../api/dashboard'
import { ARCHITECTURE_FLOW, filterSynapses, MemorySubsystems } from './memory-subsystems'

function makeSynapse(
  overrides: Partial<MemorySubsystemsSynapse> = {},
): MemorySubsystemsSynapse {
  return {
    from_agent: 'keeper-alpha',
    to_agent: 'keeper-beta',
    weight: 0.5,
    success_count: 1,
    failure_count: 0,
    last_updated: 0,
    created_at: 0,
    ...overrides,
  }
}

describe('filterSynapses', () => {
  const rows: MemorySubsystemsSynapse[] = [
    makeSynapse({ from_agent: 'keeper-alpha', to_agent: 'keeper-beta' }),
    makeSynapse({ from_agent: 'keeper-beta', to_agent: 'watcher-gamma' }),
    makeSynapse({ from_agent: 'router-delta', to_agent: 'keeper-alpha' }),
    makeSynapse({ from_agent: 'planner-epsilon', to_agent: 'router-delta' }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterSynapses(rows, '')).toBe(rows)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterSynapses(rows, '   ')).toBe(rows)
  })

  it('matches by from_agent substring (case-insensitive)', () => {
    const result = filterSynapses(rows, 'ALPHA')
    // keeper-alpha appears as from_agent in [0] and as to_agent in [2]
    expect(result).toHaveLength(2)
    expect(result.map(r => `${r.from_agent}->${r.to_agent}`)).toEqual([
      'keeper-alpha->keeper-beta',
      'router-delta->keeper-alpha',
    ])
  })

  it('matches by to_agent substring', () => {
    const result = filterSynapses(rows, 'gamma')
    expect(result.map(r => r.to_agent)).toEqual(['watcher-gamma'])
  })

  it('matches a token shared across from and to fields', () => {
    // keeper-* appears in 3 out of 4 rows
    const result = filterSynapses(rows, 'keeper')
    expect(result).toHaveLength(3)
  })

  it('returns empty when no field matches', () => {
    expect(filterSynapses(rows, 'nonexistent-needle')).toHaveLength(0)
  })

  it('trims the query before matching', () => {
    expect(filterSynapses(rows, '  router-delta  ')).toHaveLength(2)
  })

  it('does not mutate the input array', () => {
    const copy = rows.slice()
    filterSynapses(rows, 'keeper')
    expect(rows).toEqual(copy)
    expect(rows).toHaveLength(4)
  })

  it('handles an empty input array', () => {
    expect(filterSynapses([], 'keeper')).toEqual([])
    const empty: MemorySubsystemsSynapse[] = []
    expect(filterSynapses(empty, '')).toBe(empty)
  })

  it('matches partial substrings at token boundaries', () => {
    const result = filterSynapses(rows, 'router')
    // router-delta appears as from_agent in [3] and as to_agent in [3]'s twin row
    expect(result).toHaveLength(2)
    expect(result.map(r => r.from_agent)).toContain('router-delta')
    expect(result.map(r => r.to_agent)).toContain('router-delta')
  })
})

describe('ARCHITECTURE_FLOW', () => {
  // Mermaid classDef cannot lex CSS var(--token); paren confuses the property
  // delimiter and the whole diagram falls back to the parse error bomb SVG.
  // Same root cause as PR #8843 (composite-fsm-flowchart) and #11141
  // (harness-health). Keep colors as hex literals here too.
  it('uses literal hex colors in classDef (no CSS var())', () => {
    const classDefLines = ARCHITECTURE_FLOW.split('\n').filter(l => /^\s*classDef\s+/.test(l))
    expect(classDefLines.length).toBeGreaterThan(0)
    for (const line of classDefLines) {
      expect(line).not.toMatch(/var\(--/)
    }
  })
})

const baseResponse: MemorySubsystemsResponse = {
  generated_at: '2026-05-13T00:00:00Z',
  hebbian: {
    synapses: [],
    last_consolidation: 0,
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
