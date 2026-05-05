import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { activeKeeperName } from '../../keeper-state'
import { InspectorMultiKeeperBDI } from './inspector-multi-keeper-bdi'
import {
  PIN_CAP,
  clearPins,
  pinKeeper,
  pinnedKeepers,
} from './multi-keeper-pin-store'

const SCHOLAR_SNAPSHOT = {
  keeper: 'scholar',
  generated_at: '2026-05-06T00:00:00Z',
  poll_interval_ms: 5000,
  belief: 'inspect line ownership',
  desire: 'explain edit intent',
  intention: 'inspect selected line',
  need: 'recent context',
  recent_token_spend: [
    {
      ts_unix: 1777986000,
      channel: 'turn',
      model: 'glm:auto',
      input_tokens: 120,
      output_tokens: 45,
      total_tokens: 165,
    },
  ],
  last_tool_call: {
    ts_unix: 1777986100,
    tool: 'keeper_bash',
    success: true,
    semantic_outcome: 'success',
    duration_ms: 42,
  },
  source: 'keeper_meta+metrics_jsonl+tool_call_log',
}

const MOTH_SNAPSHOT = {
  ...SCHOLAR_SNAPSHOT,
  keeper: 'moth',
  belief: 'verify migration plan',
  desire: 'avoid concurrent writes',
  intention: 'inspect schema diff',
  need: null,
  recent_token_spend: [
    { ...SCHOLAR_SNAPSHOT.recent_token_spend[0], total_tokens: 240 },
  ],
  last_tool_call: { ...SCHOLAR_SNAPSHOT.last_tool_call, tool: 'keeper_search' },
}

const LUNA_SNAPSHOT = {
  ...SCHOLAR_SNAPSHOT,
  keeper: 'luna',
  belief: 'reconcile state',
  desire: 'narrow blast radius',
  intention: 'audit recent diffs',
  need: null,
  recent_token_spend: [
    { ...SCHOLAR_SNAPSHOT.recent_token_spend[0], total_tokens: 80 },
  ],
}

const ASH_SNAPSHOT = {
  ...SCHOLAR_SNAPSHOT,
  keeper: 'ash',
  belief: 'replay last incident',
  desire: 'expand observability',
  intention: 'craft retro doc',
  need: null,
  recent_token_spend: [
    { ...SCHOLAR_SNAPSHOT.recent_token_spend[0], total_tokens: 50 },
  ],
}

const SNAPSHOTS_BY_KEEPER: Record<string, unknown> = {
  scholar: SCHOLAR_SNAPSHOT,
  moth: MOTH_SNAPSHOT,
  luna: LUNA_SNAPSHOT,
  ash: ASH_SNAPSHOT,
}

const mountedContainers: HTMLElement[] = []

function createContainer(): HTMLElement {
  const container = document.createElement('div')
  mountedContainers.push(container)
  return container
}

function makeFetchMock(): ReturnType<typeof vi.fn> {
  return vi.fn(async (input: RequestInfo | URL) => {
    const url = typeof input === 'string' ? input : input.toString()
    const match = url.match(/\/api\/v1\/keepers\/([^/]+)\/bdi-snapshot/)
    const keeper = match ? decodeURIComponent(match[1]!) : ''
    const payload = SNAPSHOTS_BY_KEEPER[keeper]
    if (!payload) {
      return new Response('not found', { status: 404 })
    }
    return new Response(JSON.stringify(payload))
  })
}

beforeEach(() => {
  clearPins()
  activeKeeperName.value = ''
})

afterEach(() => {
  for (const container of mountedContainers.splice(0)) {
    render(null, container)
  }
  vi.unstubAllGlobals()
  clearPins()
  activeKeeperName.value = ''
})

describe('InspectorMultiKeeperBDI — single-pin fallback (RFC-0027 §10)', () => {
  it('delegates to legacy InspectorKeeperBDI when no keeper is pinned', async () => {
    const fetchMock = makeFetchMock()
    vi.stubGlobal('fetch', fetchMock)
    activeKeeperName.value = 'scholar'

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        '/api/v1/keepers/scholar/bdi-snapshot',
        expect.any(Object),
      )
    })

    expect(container.querySelector('[data-layout="compact-fold"]')).toBeNull()
    expect(container.querySelector('[data-layout="focus-mode"]')).toBeNull()
    expect(container.textContent).toContain('Keeper BDI')
    expect(container.textContent).toContain('scholar')
  })

  it('delegates to legacy InspectorKeeperBDI when exactly 1 keeper is pinned', async () => {
    const fetchMock = makeFetchMock()
    vi.stubGlobal('fetch', fetchMock)
    pinKeeper('scholar', 42)

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        '/api/v1/keepers/scholar/bdi-snapshot',
        expect.any(Object),
      )
    })

    expect(container.querySelector('[data-layout="compact-fold"]')).toBeNull()
    expect(container.querySelector('[data-layout="focus-mode"]')).toBeNull()
    expect(container.textContent).toContain('L42')
  })
})

describe('InspectorMultiKeeperBDI — compact-fold layout (RFC-0027 §5, 2-3 pins)', () => {
  it('renders 2 keepers with the head focused and the rest compact', async () => {
    const fetchMock = makeFetchMock()
    vi.stubGlobal('fetch', fetchMock)
    pinKeeper('scholar', 1)
    pinKeeper('moth', 2)

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      const calls = fetchMock.mock.calls.map(c => c[0])
      expect(calls).toContain('/api/v1/keepers/scholar/bdi-snapshot')
      expect(calls).toContain('/api/v1/keepers/moth/bdi-snapshot')
    })

    const root = container.querySelector('[data-layout="compact-fold"]')
    expect(root).not.toBeNull()
    expect(root?.getAttribute('data-pin-count')).toBe('2')

    const articles = container.querySelectorAll('article[role="listitem"]')
    expect(articles).toHaveLength(2)
    // Most-recent pin at head → moth focused, scholar compact.
    expect(articles[0]?.getAttribute('aria-current')).toBe('true')
    expect(articles[0]?.getAttribute('data-keeper')).toBe('moth')
    expect(articles[0]?.getAttribute('data-compact')).toBe('false')
    expect(articles[1]?.getAttribute('data-keeper')).toBe('scholar')
    expect(articles[1]?.getAttribute('data-compact')).toBe('true')
  })

  it('renders 3 keepers stacked', async () => {
    vi.stubGlobal('fetch', makeFetchMock())
    pinKeeper('scholar', 1)
    pinKeeper('moth', 2)
    pinKeeper('luna', 3)

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      const articles = container.querySelectorAll('article[role="listitem"][data-keeper]')
      expect(articles.length).toBe(3)
    })

    expect(
      container.querySelector('[data-layout="compact-fold"]')?.getAttribute('data-pin-count'),
    ).toBe('3')
  })

  it('the rollup chip aggregates total_tokens across pinned keepers', async () => {
    vi.stubGlobal('fetch', makeFetchMock())
    pinKeeper('scholar', 1) // 165
    pinKeeper('moth', 2)    // 240

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      const status = container.querySelector('[aria-label="cross-keeper token rollup"]')
      expect(status?.textContent).toContain('405')
    })
  })

  it('compact panels render Intention only (not full BDI grid)', async () => {
    vi.stubGlobal('fetch', makeFetchMock())
    pinKeeper('scholar', 1)
    pinKeeper('moth', 2)

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      const compact = container.querySelector('[data-compact="true"]')
      expect(compact?.textContent).toContain('I:')
      expect(compact?.textContent).toContain('inspect selected line')
    })

    const compact = container.querySelector('[data-compact="true"]')
    expect(compact?.textContent).not.toContain('Belief')
    expect(compact?.textContent).not.toContain('Desire')
  })

  it('clicking unpin in a panel removes that keeper from the store', async () => {
    vi.stubGlobal('fetch', makeFetchMock())
    pinKeeper('scholar', 1)
    pinKeeper('moth', 2)

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      expect(container.querySelectorAll('article[role="listitem"]').length).toBe(2)
    })

    const unpinScholar = container.querySelector('button[aria-label="unpin scholar"]') as HTMLButtonElement | null
    expect(unpinScholar).not.toBeNull()
    unpinScholar?.click()

    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['moth'])
  })
})

describe('InspectorMultiKeeperBDI — focus-mode layout (RFC-0027 §5, exactly PIN_CAP pins)', () => {
  function pin4(): void {
    pinKeeper('scholar', 1)
    pinKeeper('moth', 2)
    pinKeeper('luna', 3)
    pinKeeper('ash', 4)
  }

  it('renders 1 focused panel and 3 promote-to-focus chips at the cap', async () => {
    vi.stubGlobal('fetch', makeFetchMock())
    pin4()

    expect(pinnedKeepers.value.entries.length).toBe(PIN_CAP)

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      const root = container.querySelector('[data-layout="focus-mode"]')
      expect(root?.getAttribute('data-pin-count')).toBe('4')
    })

    const articles = container.querySelectorAll('article[role="listitem"]')
    expect(articles.length).toBe(1)
    expect(articles[0]?.getAttribute('data-keeper')).toBe('ash') // most recent

    const chips = container.querySelectorAll('[role="group"][aria-label="other pinned keepers"] [role="listitem"]')
    expect(chips.length).toBe(3)
    const chipNames = Array.from(chips).map(c => c.getAttribute('data-keeper'))
    expect(chipNames).toEqual(['luna', 'moth', 'scholar'])
  })

  it('clicking a chip promotes that keeper to the focused slot', async () => {
    vi.stubGlobal('fetch', makeFetchMock())
    pin4()

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      expect(container.querySelector('[data-layout="focus-mode"]')).not.toBeNull()
    })

    const focusBtn = container.querySelector('button[aria-label="focus scholar"]') as HTMLButtonElement | null
    expect(focusBtn).not.toBeNull()
    focusBtn?.click()

    expect(pinnedKeepers.value.entries[0]?.keeperName).toBe('scholar')
    expect(pinnedKeepers.value.entries.length).toBe(PIN_CAP)
  })

  it('clicking unpin on a chip removes that keeper without disturbing focus', async () => {
    vi.stubGlobal('fetch', makeFetchMock())
    pin4()

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      expect(container.querySelector('[data-layout="focus-mode"]')).not.toBeNull()
    })

    const unpinBtn = container.querySelector('button[aria-label="unpin moth"]') as HTMLButtonElement | null
    expect(unpinBtn).not.toBeNull()
    unpinBtn?.click()

    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['ash', 'luna', 'scholar'])
  })

  it('rollup aggregates across all 4 pinned keepers', async () => {
    vi.stubGlobal('fetch', makeFetchMock())
    pin4()

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      const status = container.querySelector('[aria-label="cross-keeper token rollup"]')
      // 165 + 240 + 80 + 50 = 535
      expect(status?.textContent).toContain('535')
    })
  })
})

describe('InspectorMultiKeeperBDI — error handling', () => {
  it('shows a per-panel snapshot-unavailable status when one keeper 404s', async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = typeof input === 'string' ? input : input.toString()
      if (url.includes('moth')) {
        return new Response('not found', { status: 404 })
      }
      return new Response(JSON.stringify(SCHOLAR_SNAPSHOT))
    })
    vi.stubGlobal('fetch', fetchMock)

    pinKeeper('scholar', 1)
    pinKeeper('moth', 2)

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      const mothPanel = container.querySelector('[data-keeper="moth"]')
      expect(mothPanel?.textContent).toContain('snapshot unavailable')
    })

    const scholarPanel = container.querySelector('[data-keeper="scholar"]')
    expect(scholarPanel?.textContent).not.toContain('snapshot unavailable')
  })
})
