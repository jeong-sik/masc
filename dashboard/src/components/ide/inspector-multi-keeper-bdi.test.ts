import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { activeKeeperName } from '../../keeper-state'
import {
  InspectorMultiKeeperBDI,
  KEEPER_DRAG_MIME,
  buildDragHandlers,
} from './inspector-multi-keeper-bdi'
import {
  PIN_CAP,
  clearPins,
  pinKeeper,
  pinnedKeepers,
} from './multi-keeper-pin-store'
import { cursorOverlaySignal, type KeeperCursor } from './keeper-cursor-overlay'
import { activeIdeFile } from './ide-shell'

function setKeeperCursor(keeperId: string, filePath: string, line: number): void {
  const cursors = new Map(cursorOverlaySignal.value.cursors)
  const cursor: KeeperCursor = {
    keeper_id: keeperId,
    file_path: filePath,
    line,
    column: 0,
    focus_mode: 'reading',
    last_update: Date.now(),
  }
  cursors.set(keeperId, cursor)
  cursorOverlaySignal.value = { ...cursorOverlaySignal.value, cursors }
}

function clearKeeperCursors(): void {
  cursorOverlaySignal.value = { ...cursorOverlaySignal.value, cursors: new Map() }
}

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
  clearKeeperCursors()
  activeIdeFile.value = 'package.json'
})

afterEach(() => {
  for (const container of mountedContainers.splice(0)) {
    render(null, container)
  }
  vi.unstubAllGlobals()
  clearPins()
  activeKeeperName.value = ''
  clearKeeperCursors()
  activeIdeFile.value = 'package.json'
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

describe('InspectorMultiKeeperBDI — drag reorder wiring (RFC-0027 PR-γ §4)', () => {
  // Component-level smoke: verify the drag scaffolding is on the rendered DOM.
  // Behavior of the handlers themselves is unit-tested in the
  // `buildDragHandlers` block below — Preact event dispatch on synthetic
  // `Event` objects is unreliable in jsdom, so we keep the integration test
  // surface narrow.
  it('panels in compact-fold have draggable=true and consecutive data-drop-idx', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(SCHOLAR_SNAPSHOT))))
    pinKeeper('scholar', 1)
    pinKeeper('moth', 2)

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      expect(container.querySelectorAll('article[role="listitem"]').length).toBe(2)
    })

    const panels = Array.from(container.querySelectorAll('article[role="listitem"]'))
    expect(panels.every(p => p.getAttribute('draggable') === 'true')).toBe(true)
    expect(panels.map(p => p.getAttribute('data-drop-idx'))).toEqual(['0', '1'])
  })

  it('focus-mode focused panel has drop-idx 0 and chips have drop-idx 1..3', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(SCHOLAR_SNAPSHOT))))
    pinKeeper('a', 1)
    pinKeeper('b', 2)
    pinKeeper('c', 3)
    pinKeeper('d', 4)
    expect(pinnedKeepers.value.entries.length).toBe(PIN_CAP)

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      expect(container.querySelector('[data-layout="focus-mode"]')).not.toBeNull()
    })

    const focusedPanel = container.querySelector('article[data-drop-idx="0"]')
    expect(focusedPanel?.getAttribute('data-keeper')).toBe('d')

    const chips = Array.from(container.querySelectorAll('span[role="listitem"]'))
    expect(chips.every(c => c.getAttribute('draggable') === 'true')).toBe(true)
    expect(chips.map(c => c.getAttribute('data-drop-idx'))).toEqual(['1', '2', '3'])
  })
})

describe('buildDragHandlers — RFC-0027 PR-γ §4 unit', () => {
  interface SimulatedDataTransfer {
    _data: Map<string, string>
    _types: string[]
    effectAllowed: string
    dropEffect: string
    setData: (format: string, data: string) => void
    getData: (format: string) => string
    readonly types: ReadonlyArray<string>
  }

  function makeDataTransfer(initial?: { mime: string; data?: string }): SimulatedDataTransfer {
    const dt: SimulatedDataTransfer = {
      _data: new Map(),
      _types: initial?.mime ? [initial.mime] : [],
      effectAllowed: '',
      dropEffect: '',
      setData(format: string, data: string) {
        this._data.set(format, data)
        if (!this._types.includes(format)) this._types.push(format)
      },
      getData(format: string) {
        return this._data.get(format) ?? ''
      },
      get types() {
        return this._types
      },
    }
    if (initial?.mime && initial.data !== undefined) {
      dt._data.set(initial.mime, initial.data)
    }
    return dt
  }

  function makeEvent(dt: SimulatedDataTransfer | null): DragEvent {
    let prevented = false
    return {
      dataTransfer: dt,
      preventDefault() {
        prevented = true
      },
      get defaultPrevented() {
        return prevented
      },
    } as unknown as DragEvent
  }

  beforeEach(() => {
    clearPins()
  })

  afterEach(() => {
    clearPins()
  })

  it('onDragStart writes the source name to the keeper MIME and sets effectAllowed=move', () => {
    const handlers = buildDragHandlers('scholar', 0)
    const dt = makeDataTransfer()
    handlers.onDragStart(makeEvent(dt))
    expect(dt.getData(KEEPER_DRAG_MIME)).toBe('scholar')
    expect(dt.effectAllowed).toBe('move')
  })

  it('onDragStart is a no-op when dataTransfer is null', () => {
    const handlers = buildDragHandlers('scholar', 0)
    expect(() => handlers.onDragStart(makeEvent(null))).not.toThrow()
  })

  it('onDragOver with keeper MIME calls preventDefault and sets dropEffect=move', () => {
    const handlers = buildDragHandlers('scholar', 0)
    const dt = makeDataTransfer({ mime: KEEPER_DRAG_MIME })
    const event = makeEvent(dt)
    handlers.onDragOver(event)
    expect(event.defaultPrevented).toBe(true)
    expect(dt.dropEffect).toBe('move')
  })

  it('onDragOver with non-keeper MIME does NOT preventDefault', () => {
    const handlers = buildDragHandlers('scholar', 0)
    const dt = makeDataTransfer({ mime: 'text/plain' })
    const event = makeEvent(dt)
    handlers.onDragOver(event)
    expect(event.defaultPrevented).toBe(false)
  })

  it('onDrop with keeper MIME and a different source calls reorderPins', () => {
    pinKeeper('a', 1)
    pinKeeper('b', 2)
    pinKeeper('c', 3)
    // Head order: ['c','b','a']

    // Drop 'a' onto target 'c' (drop-idx 0).
    const handlers = buildDragHandlers('c', 0)
    const dt = makeDataTransfer({ mime: KEEPER_DRAG_MIME, data: 'a' })
    const event = makeEvent(dt)
    handlers.onDrop(event)

    expect(event.defaultPrevented).toBe(true)
    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['a', 'c', 'b'])
  })

  it('onDrop on the same keeper (self-drop) is a no-op', () => {
    pinKeeper('a', 1)
    pinKeeper('b', 2)

    const stateBefore = pinnedKeepers.value
    const handlers = buildDragHandlers('b', 0)
    const dt = makeDataTransfer({ mime: KEEPER_DRAG_MIME, data: 'b' })
    handlers.onDrop(makeEvent(dt))
    expect(pinnedKeepers.value).toBe(stateBefore)
  })

  it('onDrop with empty source name is a no-op', () => {
    pinKeeper('a', 1)
    pinKeeper('b', 2)

    const stateBefore = pinnedKeepers.value
    const handlers = buildDragHandlers('a', 1)
    const dt = makeDataTransfer({ mime: KEEPER_DRAG_MIME, data: '' })
    handlers.onDrop(makeEvent(dt))
    expect(pinnedKeepers.value).toBe(stateBefore)
  })

  it('onDrop on a chip target reorders the source into that chip slot', () => {
    pinKeeper('a', 1)
    pinKeeper('b', 2)
    pinKeeper('c', 3)
    pinKeeper('d', 4)
    // Head order: ['d','c','b','a']

    // Drag 'd' onto chip at drop-idx 3 ('a').
    const handlers = buildDragHandlers('a', 3)
    const dt = makeDataTransfer({ mime: KEEPER_DRAG_MIME, data: 'd' })
    handlers.onDrop(makeEvent(dt))

    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['c', 'b', 'a', 'd'])
  })
})

describe('InspectorMultiKeeperBDI — file focus label (cursor overlay → IDE jump)', () => {
  it('renders no focus label when the keeper has no cursor in the overlay', async () => {
    vi.stubGlobal('fetch', makeFetchMock())
    pinKeeper('scholar', 1)
    pinKeeper('moth', 2)
    // No setKeeperCursor calls — cursors map empty.

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      expect(container.querySelectorAll('article[role="listitem"]').length).toBe(2)
    })

    expect(container.querySelector('button[aria-label^="focus file "]')).toBeNull()
  })

  it('renders the file:line label on the focused compact-fold panel when cursor is present', async () => {
    vi.stubGlobal('fetch', makeFetchMock())
    pinKeeper('scholar', 1)
    pinKeeper('moth', 2)
    // moth is at the head (most-recent) → focused panel.
    setKeeperCursor('moth', 'src/components/ide/inspector-multi-keeper-bdi.ts', 318)

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      expect(container.querySelectorAll('article[role="listitem"]').length).toBe(2)
    })

    const mothPanel = container.querySelector('article[data-keeper="moth"]')
    expect(mothPanel).not.toBeNull()
    // Basename + line — no directory prefix.
    const focusBtn = mothPanel?.querySelector('button[aria-label^="focus file "]') as HTMLButtonElement | null
    expect(focusBtn).not.toBeNull()
    expect(focusBtn?.textContent).toBe('inspector-multi-keeper-bdi.ts:318')
    // Full path lives in the title attribute and aria-label.
    expect(focusBtn?.title).toBe('src/components/ide/inspector-multi-keeper-bdi.ts')
  })

  it('clicking the panel focus label updates activeIdeFile to the full path', async () => {
    vi.stubGlobal('fetch', makeFetchMock())
    pinKeeper('scholar', 1)
    pinKeeper('moth', 2)
    setKeeperCursor('moth', 'src/runtime/router.ts', 42)

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      const btn = container.querySelector('article[data-keeper="moth"] button[aria-label^="focus file "]')
      expect(btn).not.toBeNull()
    })

    const focusBtn = container.querySelector(
      'article[data-keeper="moth"] button[aria-label^="focus file "]',
    ) as HTMLButtonElement
    focusBtn.click()
    expect(activeIdeFile.value).toBe('src/runtime/router.ts')
  })

  it('focus-mode chip renders file:line label and clicking jumps without re-focusing the keeper', async () => {
    vi.stubGlobal('fetch', makeFetchMock())
    pinKeeper('scholar', 1)
    pinKeeper('moth', 2)
    pinKeeper('luna', 3)
    pinKeeper('ash', 4)
    // ash is focused (head). scholar/moth/luna become chips.
    setKeeperCursor('scholar', 'lib/keeper/keeper_registry.ml', 555)

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      expect(container.querySelector('[data-layout="focus-mode"]')).not.toBeNull()
    })

    const scholarChip = container.querySelector('span[role="listitem"][data-keeper="scholar"]')
    expect(scholarChip).not.toBeNull()

    // No focusable role="button" span (Thread 1 fix): only real <button> elements.
    expect(scholarChip?.querySelector('span[role="button"]')).toBeNull()

    const fileBtn = scholarChip?.querySelector('button[aria-label^="focus file "]') as HTMLButtonElement | null
    expect(fileBtn).not.toBeNull()
    expect(fileBtn?.textContent).toBe('keeper_registry.ml:555')

    const headBefore = pinnedKeepers.value.entries[0]?.keeperName
    fileBtn?.click()
    // activeIdeFile jumped …
    expect(activeIdeFile.value).toBe('lib/keeper/keeper_registry.ml')
    // … but pin order untouched (focus-promote did NOT fire because the focus
    // label is now a sibling button, not nested inside the focus chip button).
    expect(pinnedKeepers.value.entries[0]?.keeperName).toBe(headBefore)
  })

  it('chip focus-file button is a sibling of the focus button (no nested interactive descendants)', async () => {
    vi.stubGlobal('fetch', makeFetchMock())
    pinKeeper('a', 1)
    pinKeeper('b', 2)
    pinKeeper('c', 3)
    pinKeeper('d', 4)
    setKeeperCursor('a', 'README.md', 7)

    const container = createContainer()
    render(html`<${InspectorMultiKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      expect(container.querySelector('[data-layout="focus-mode"]')).not.toBeNull()
    })

    const chip = container.querySelector('span[role="listitem"][data-keeper="a"]')!
    const focusBtn = chip.querySelector('button[aria-label="focus a"]')!
    // Focus-file button must NOT be a descendant of the focus button.
    expect(focusBtn.querySelector('button[aria-label^="focus file "]')).toBeNull()
    expect(chip.querySelector('button[aria-label^="focus file "]')).not.toBeNull()
  })
})
