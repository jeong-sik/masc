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
  inspectorKeeperPin.value = null
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
})
