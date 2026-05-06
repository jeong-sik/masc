import { afterEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { activeKeeperName } from '../../keeper-state'
import {
  InspectorKeeperBDI,
  inspectorKeeperPin,
  normalizeKeeperBdiSnapshot,
  pinInspectorKeeper,
} from './inspector-keeper-bdi'
import { clearPins } from './multi-keeper-pin-store'
import { clearTraces, pushTrace } from './keeper-trace-store'

const snapshot = {
  keeper: 'scholar',
  generated_at: '2026-05-05T13:00:00Z',
  poll_interval_ms: 5000,
  belief: 'line ownership needs inspection',
  desire: 'explain current edit intent',
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

const mountedContainers: HTMLElement[] = []

function createContainer(): HTMLElement {
  const container = document.createElement('div')
  mountedContainers.push(container)
  return container
}

afterEach(() => {
  for (const container of mountedContainers.splice(0)) {
    render(null, container)
  }
  vi.unstubAllGlobals()
  activeKeeperName.value = ''
  clearPins()
  clearTraces()
  void inspectorKeeperPin.value
})

describe('normalizeKeeperBdiSnapshot', () => {
  it('normalizes BDI fields, token spend, and the latest tool call', () => {
    const normalized = normalizeKeeperBdiSnapshot(snapshot)
    expect(normalized?.keeper).toBe('scholar')
    expect(normalized?.belief).toBe('line ownership needs inspection')
    expect(normalized?.desire).toBe('explain current edit intent')
    expect(normalized?.intention).toBe('inspect selected line')
    expect(normalized?.recent_token_spend[0]?.total_tokens).toBe(165)
    expect(normalized?.last_tool_call?.tool).toBe('keeper_bash')
  })

  it('rejects payloads without a keeper name', () => {
    expect(normalizeKeeperBdiSnapshot({ belief: 'missing keeper' })).toBeNull()
  })
})

describe('InspectorKeeperBDI', () => {
  it('pins selected keeper/line and renders the BDI snapshot', async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify(snapshot)))
    vi.stubGlobal('fetch', fetchMock)
    pinInspectorKeeper('scholar', 42)

    const container = createContainer()
    render(html`<${InspectorKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith('/api/v1/keepers/scholar/bdi-snapshot', expect.any(Object))
    })

    expect(container.textContent).toContain('Keeper BDI')
    expect(container.textContent).toContain('scholar')
    expect(container.textContent).toContain('L42')
    expect(container.textContent).toContain('line ownership needs inspection')
    expect(container.textContent).toContain('165 tok')
    expect(container.textContent).toContain('keeper_bash')

    render(null, container)
  })

  it('falls back to the active keeper when no line is pinned', async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify(snapshot)))
    vi.stubGlobal('fetch', fetchMock)
    activeKeeperName.value = 'scholar'

    const container = createContainer()
    render(html`<${InspectorKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith('/api/v1/keepers/scholar/bdi-snapshot', expect.any(Object))
    })

    expect(container.textContent).toContain('scholar')

    render(null, container)
  })

  it('mounts the keeper-trace overlay scoped to this keeper when traceActive is true', async () => {
    pushTrace({
      id: 'inspector-trace-self',
      tsMs: Date.parse('2026-05-06T01:00:00Z'),
      keeperName: 'scholar',
      source: 'bdi-snapshot',
      intention: 'inspect selected line',
    })
    pushTrace({
      id: 'inspector-trace-other',
      tsMs: Date.parse('2026-05-06T01:00:00Z'),
      keeperName: 'tech_glutton',
      source: 'bdi-snapshot',
      intention: 'should not appear',
    })

    const fetchMock = vi.fn(async () => new Response(JSON.stringify(snapshot)))
    vi.stubGlobal('fetch', fetchMock)
    pinInspectorKeeper('scholar', 42)

    const container = createContainer()
    render(html`<${InspectorKeeperBDI} pollMs=${60_000} traceActive=${true} />`, container)
    await vi.waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith('/api/v1/keepers/scholar/bdi-snapshot', expect.any(Object))
    })

    const overlay = container.querySelector('[data-overlay="keeper-trace"]')
    expect(overlay).not.toBeNull()

    const scholarBucket = overlay?.querySelector('[data-keeper="scholar"]')
    expect(scholarBucket).not.toBeNull()

    const otherBucket = overlay?.querySelector('[data-keeper="tech_glutton"]')
    expect(otherBucket).toBeNull()

    render(null, container)
  })

  it('does not render the keeper-trace overlay when traceActive is false (default)', async () => {
    pushTrace({
      id: 'inspector-trace-default-off',
      tsMs: Date.parse('2026-05-06T01:00:00Z'),
      keeperName: 'scholar',
      source: 'bdi-snapshot',
      intention: 'inspect selected line',
    })

    const fetchMock = vi.fn(async () => new Response(JSON.stringify(snapshot)))
    vi.stubGlobal('fetch', fetchMock)
    pinInspectorKeeper('scholar', 42)

    const container = createContainer()
    render(html`<${InspectorKeeperBDI} pollMs=${60_000} />`, container)
    await vi.waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith('/api/v1/keepers/scholar/bdi-snapshot', expect.any(Object))
    })

    const overlay = container.querySelector('[data-overlay="keeper-trace"]')
    expect(overlay).toBeNull()

    render(null, container)
  })

  it('trims whitespace from the keeper name so polling and overlay filter stay consistent', async () => {
    pushTrace({
      id: 'inspector-trace-trimmed',
      tsMs: Date.parse('2026-05-06T01:00:00Z'),
      keeperName: 'scholar',
      source: 'bdi-snapshot',
      intention: 'inspect selected line',
    })

    const fetchMock = vi.fn(async () => new Response(JSON.stringify(snapshot)))
    vi.stubGlobal('fetch', fetchMock)
    activeKeeperName.value = '  scholar  '

    const container = createContainer()
    render(html`<${InspectorKeeperBDI} pollMs=${60_000} traceActive=${true} />`, container)
    await vi.waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith('/api/v1/keepers/scholar/bdi-snapshot', expect.any(Object))
    })

    const overlay = container.querySelector('[data-overlay="keeper-trace"]')
    expect(overlay).not.toBeNull()
    expect(overlay?.querySelector('[data-keeper="scholar"]')).not.toBeNull()

    render(null, container)
  })
})
