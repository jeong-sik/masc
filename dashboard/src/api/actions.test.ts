import { afterEach, describe, expect, it, vi } from 'vitest'
import { ACTIVITY_TIMEOUT_MS } from '../config/constants'

const {
  get,
  parseActivityGraphResponse,
  parseSwimlaneResponse,
} = vi.hoisted(() => ({
  get: vi.fn(),
  parseActivityGraphResponse: vi.fn(),
  parseSwimlaneResponse: vi.fn(),
}))

vi.mock('./core', () => ({
  get,
  post: vi.fn(),
}))

vi.mock('./mcp', () => ({
  callMcpTool: vi.fn(),
}))

vi.mock('./schemas/actions-activity', () => ({
  ActionsActivitySchemaDriftError: class ActionsActivitySchemaDriftError extends Error {},
  parseActivityGraphResponse,
  parseSwimlaneResponse,
}))

afterEach(() => {
  vi.clearAllMocks()
  vi.resetModules()
})

describe('fetchActivityGraph', () => {
  it('uses ACTIVITY_TIMEOUT_MS and omits actor headers', async () => {
    const raw = { nodes: [], edges: [] }
    const parsed = { nodes: [], edges: [], stats: {}, kind_counts: {}, heatmap: { matrix: [], max: 0, total: 0 }, timeline: [], generated_at: '2026-04-18T00:00:00Z', window: { limit: 0, room_id: null, kinds: [] } }
    get.mockResolvedValue(raw)
    parseActivityGraphResponse.mockReturnValue(parsed)

    const { fetchActivityGraph } = await import('./actions')
    const result = await fetchActivityGraph('2026-04-18T00:00:00Z')

    expect(get).toHaveBeenCalledWith('/api/v1/activity/graph?since=2026-04-18T00:00:00Z', {
      timeoutMs: ACTIVITY_TIMEOUT_MS,
      includeActorHeader: false,
      signal: undefined,
    })
    expect(parseActivityGraphResponse).toHaveBeenCalledWith(raw)
    expect(result).toBe(parsed)
  })

  it('treats 200 not-initialized envelopes as warm-up instead of schema drift', async () => {
    get.mockResolvedValue({ error: 'not initialized' })

    const { fetchActivityGraph } = await import('./actions')
    const result = await fetchActivityGraph('1h')

    expect(parseActivityGraphResponse).not.toHaveBeenCalled()
    expect(result).toBeNull()
  })
})

describe('fetchSwimlane', () => {
  it('uses ACTIVITY_TIMEOUT_MS and omits actor headers', async () => {
    const raw = { agents: [], spans: [] }
    const parsed = { agents: [], spans: [], time_range: { min_ms: 0, max_ms: 0 } }
    get.mockResolvedValue(raw)
    parseSwimlaneResponse.mockReturnValue(parsed)

    const { fetchSwimlane } = await import('./actions')
    const result = await fetchSwimlane()

    expect(get).toHaveBeenCalledWith('/api/v1/activity/swimlane', {
      timeoutMs: ACTIVITY_TIMEOUT_MS,
      includeActorHeader: false,
      signal: undefined,
    })
    expect(parseSwimlaneResponse).toHaveBeenCalledWith(raw)
    expect(result).toBe(parsed)
  })

  it('treats 200 not-initialized swimlane envelopes as warm-up instead of schema drift', async () => {
    get.mockResolvedValue({ error: 'not initialized' })

    const { fetchSwimlane } = await import('./actions')
    const result = await fetchSwimlane('1h')

    expect(parseSwimlaneResponse).not.toHaveBeenCalled()
    expect(result).toBeNull()
  })
})
