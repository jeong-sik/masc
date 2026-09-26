import { afterEach, describe, expect, it, vi } from 'vitest'
import { fetchIdeEvents } from './ide'
import { clearStoredToken } from './core'

const mockFetch = vi.fn()

afterEach(() => {
  mockFetch.mockReset()
  vi.unstubAllGlobals()
  clearStoredToken()
})

function stubFetch(response: unknown, ok = true, status?: number): void {
  mockFetch.mockResolvedValue({
    ok,
    status: status ?? (ok ? 200 : 500),
    statusText: ok ? 'OK' : 'Internal Server Error',
    headers: new Headers(),
    json: () => Promise.resolve(response),
    text: () => Promise.resolve(JSON.stringify(response)),
    clone() { return this },
  } as Response)
  vi.stubGlobal('fetch', mockFetch)
}

describe('ide API', () => {
  it('fetchIdeEvents appends event filters and parses bridge events', async () => {
    stubFetch({
      ok: true,
      data: {
        events: [{
          type: 'tool',
          tool_name: 'execute',
          keeper_id: 'sangsu',
          turn_id: 'turn-1',
          outcome: 'success',
          typed_outcome: 'progress',
          latency_ms: 50,
          summary: 'ran command',
          file_path: 'lib/a.ml',
          timestamp_ms: '1717400000000',
          event_id: 'a'.repeat(64),
        }],
      },
    })

    const events = await fetchIdeEvents({
      kind: 'tool',
      keeperId: 'sangsu',
      codebase: 'github.com_jeong-sik_masc',
      limit: 25,
    })

    const url = String(mockFetch.mock.calls[0]![0])
    expect(url).toContain('/api/v1/ide/events?')
    expect(url).toContain('kind=tool')
    expect(url).toContain('keeper_id=sangsu')
    expect(url).toContain('codebase=github.com_jeong-sik_masc')
    expect(url).toContain('limit=25')
    expect(events).toEqual([expect.objectContaining({
      type: 'tool',
      tool_name: 'execute',
      keeper_id: 'sangsu',
      turn_id: 'turn-1',
      timestamp_ms: 1717400000000,
      event_id: 'a'.repeat(64),
    })])
  })

  it('rejects two codebase authorities before issuing a request', async () => {
    stubFetch({ ok: true, data: { events: [] } })

    await expect(fetchIdeEvents({
      scope: { kind: 'codebase', codebase: 'github.com_other_repo' },
      codebase: 'github.com_jeong-sik_masc',
    })).rejects.toThrow('IDE scope must resolve to exactly one')
    expect(mockFetch).not.toHaveBeenCalled()
  })

  it('fetchIdeEvents rejects malformed event rows instead of dropping them', async () => {
    stubFetch({
      ok: true,
      data: {
        events: [{
          type: 'tool',
          keeper_id: 'sangsu',
          turn_id: 'turn-1',
          timestamp_ms: 1717400000000,
        }],
      },
    })

    await expect(fetchIdeEvents()).rejects.toThrow(
      'fetchIdeEvents returned malformed event at index 0',
    )
  })

  // A tool that printed nothing is written with summary "" (ide_bridge.ml
  // keeps the output head verbatim). Rejecting that row threw away the
  // whole page of events, so one quiet tool call blanked the timeline.
  it('fetchIdeEvents keeps a tool row whose output was empty', async () => {
    stubFetch({
      ok: true,
      data: {
        events: [{
          type: 'tool',
          tool_name: 'execute',
          keeper_id: 'sangsu',
          turn_id: 'turn-1',
          outcome: 'success',
          typed_outcome: 'progress',
          latency_ms: 5,
          summary: '',
          file_path: 'lib/a.ml',
          timestamp_ms: 1717400000000,
        }],
      },
    })

    const events = await fetchIdeEvents({ codebase: 'github.com_jeong-sik_masc' })
    expect(events).toEqual([expect.objectContaining({ type: 'tool', summary: null })])
  })

  it('fetchIdeEvents still rejects a tool row with no summary field', async () => {
    stubFetch({
      ok: true,
      data: {
        events: [{
          type: 'tool',
          tool_name: 'execute',
          keeper_id: 'sangsu',
          turn_id: 'turn-1',
          outcome: 'success',
          typed_outcome: 'progress',
          latency_ms: 5,
          timestamp_ms: 1717400000000,
        }],
      },
    })

    await expect(fetchIdeEvents({ codebase: 'github.com_jeong-sik_masc' })).rejects.toThrow(
      'fetchIdeEvents returned malformed event at index 0',
    )
  })

})
