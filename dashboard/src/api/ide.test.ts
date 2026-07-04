import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  createIdeAnnotation,
  deleteIdeAnnotation,
  fetchIdeAnnotations,
  fetchIdeCursors,
  fetchIdeEvents,
  fetchIdeRegions,
} from './ide'

const mockFetch = vi.fn()

afterEach(() => {
  mockFetch.mockReset()
  vi.unstubAllGlobals()
})

function stubFetch(response: unknown, ok = true): void {
  mockFetch.mockResolvedValue({
    ok,
    status: ok ? 200 : 500,
    statusText: ok ? 'OK' : 'Internal Server Error',
    headers: new Headers(),
    json: () => Promise.resolve(response),
    text: () => Promise.resolve(JSON.stringify(response)),
    clone() { return this },
  } as Response)
  vi.stubGlobal('fetch', mockFetch)
}

const annotation = {
  id: 'ann-1',
  file_path: 'lib/a.ml',
  line_start: 1,
  line_end: 1,
  keeper_id: 'sangsu',
  kind: 'Comment',
  content: 'Review this line',
  goal_id: null,
  task_id: null,
  created_at_ms: 1,
  updated_at_ms: 1,
}

const region = {
  file_path: 'lib/a.ml',
  line_start: 1,
  line_end: 1,
  keeper_id: 'sangsu',
  source: { type: 'tool_call', tool_name: 'write_file', turn: 7 },
  timestamp_ms: 1,
}

describe('ide API', () => {
  it('fetchIdeAnnotations appends keeper and repo_id params', async () => {
    stubFetch({ ok: true, data: [annotation] })

    await fetchIdeAnnotations(
      { file_path: 'lib/a.ml' },
      { keeper: 'sangsu', repoId: 'masc' },
    )

    const url = String(mockFetch.mock.calls[0]![0])
    expect(url).toContain('/api/v1/ide/annotations?')
    expect(url).toContain('file_path=lib%2Fa.ml')
    expect(url).toContain('keeper=sangsu')
    expect(url).toContain('repo_id=masc')
  })

  it('fetchIdeAnnotations rejects failed envelopes instead of returning empty', async () => {
    stubFetch({ ok: false, error: 'repo scope unmatched' })

    await expect(fetchIdeAnnotations()).rejects.toThrow('repo scope unmatched')
  })

  it('fetchIdeAnnotations rejects malformed rows instead of dropping them', async () => {
    stubFetch({ ok: true, data: [null] })

    await expect(fetchIdeAnnotations()).rejects.toThrow(
      'fetchIdeAnnotations returned malformed row at index 0',
    )
  })

  it('fetchIdeAnnotations rejects rows with missing required fields', async () => {
    stubFetch({ ok: true, data: [{ ...annotation, id: '' }] })

    await expect(fetchIdeAnnotations()).rejects.toThrow(
      'fetchIdeAnnotations returned malformed row at index 0',
    )
  })

  it('createIdeAnnotation relies on token identity and appends workspace params', async () => {
    stubFetch({ ok: true, data: annotation })

    await createIdeAnnotation({
      file_path: 'lib/a.ml',
      line_start: 1,
      line_end: 1,
      kind: 'Comment',
      content: 'Review this line',
    }, { keeper: 'sangsu', repoId: 'masc' })

    const url = String(mockFetch.mock.calls[0]![0])
    const init = mockFetch.mock.calls[0]![1] as RequestInit
    const body = JSON.parse(String(init.body)) as Record<string, unknown>
    expect(url).toContain('/api/v1/ide/annotations?')
    expect(url).toContain('keeper=sangsu')
    expect(url).toContain('repo_id=masc')
    expect(body).not.toHaveProperty('keeper_id')
  })

  it('createIdeAnnotation rejects failed envelopes instead of returning null', async () => {
    stubFetch({ ok: false, error: 'annotation denied' })

    await expect(createIdeAnnotation({
      file_path: 'lib/a.ml',
      line_start: 1,
      line_end: 1,
      kind: 'Comment',
      content: 'Review this line',
    })).rejects.toThrow('annotation denied')
  })

  it('createIdeAnnotation rejects malformed annotation rows', async () => {
    stubFetch({ ok: true, data: { ...annotation, created_at_ms: null } })

    await expect(createIdeAnnotation({
      file_path: 'lib/a.ml',
      line_start: 1,
      line_end: 1,
      kind: 'Comment',
      content: 'Review this line',
    })).rejects.toThrow('createIdeAnnotation returned malformed row')
  })

  it('fetchIdeRegions appends repo_id param', async () => {
    stubFetch({ ok: true, data: [region] })

    await fetchIdeRegions('lib/a.ml', { repoId: 'masc' })

    const url = String(mockFetch.mock.calls[0]![0])
    expect(url).toContain('/api/v1/ide/regions?')
    expect(url).toContain('file_path=lib%2Fa.ml')
    expect(url).toContain('repo_id=masc')
  })

  it('fetchIdeRegions rejects malformed response data', async () => {
    stubFetch({ ok: true, data: { regions: [] } })

    await expect(fetchIdeRegions('lib/a.ml')).rejects.toThrow(
      'fetchIdeRegions returned malformed data',
    )
  })

  it('fetchIdeRegions rejects malformed region rows instead of coercing defaults', async () => {
    stubFetch({ ok: true, data: [{ ...region, source: { type: 'legacy' } }] })

    await expect(fetchIdeRegions('lib/a.ml')).rejects.toThrow(
      'fetchIdeRegions returned malformed row at index 0',
    )
  })

  it('deleteIdeAnnotation relies on token identity and appends repo_id param', async () => {
    stubFetch({}, true)

    await deleteIdeAnnotation('ann-1', { repoId: 'masc' })

    const url = String(mockFetch.mock.calls[0]![0])
    expect(url).toContain('/api/v1/ide/annotations/ann-1?')
    expect(url).toContain('repo_id=masc')
    expect(url).not.toContain('keeper_id=')
  })

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
          command_descriptor: null,
          timestamp_ms: '1717400000000',
        }],
      },
    })

    const events = await fetchIdeEvents({
      kind: 'tool',
      keeperId: 'sangsu',
      repoId: 'masc',
      limit: 25,
    })

    const url = String(mockFetch.mock.calls[0]![0])
    expect(url).toContain('/api/v1/ide/events?')
    expect(url).toContain('kind=tool')
    expect(url).toContain('keeper_id=sangsu')
    expect(url).toContain('repo_id=masc')
    expect(url).toContain('limit=25')
    expect(events).toEqual([expect.objectContaining({
      type: 'tool',
      tool_name: 'execute',
      keeper_id: 'sangsu',
      turn_id: 'turn-1',
      timestamp_ms: 1717400000000,
    })])
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

  it('fetchIdeCursors appends cursor filters and parses valid cursor rows', async () => {
    stubFetch({
      ok: true,
      data: {
        runtime_id: 'masc-runtime',
        branch: 'main',
        connected: true,
        cursors: [{
          keeper_id: 'sangsu',
          file_path: 'lib/a.ml',
          line: 12,
          column: 3,
          selection_end: { line: 14, column: 3 },
          focus_mode: 'editing',
          last_update: '1717400000000',
          tool_name: 'keeper_ide_annotate',
          turn: 7,
        }],
      },
    })

    const snapshot = await fetchIdeCursors({
      keeperId: 'sangsu',
      filePath: 'lib/a.ml',
      repoId: 'masc',
      limit: 10,
    })

    const url = String(mockFetch.mock.calls[0]![0])
    expect(url).toContain('/api/v1/ide/cursors?')
    expect(url).toContain('keeper_id=sangsu')
    expect(url).toContain('file_path=lib%2Fa.ml')
    expect(url).toContain('repo_id=masc')
    expect(url).toContain('limit=10')
    expect(snapshot?.cursors).toEqual([expect.objectContaining({
      keeper_id: 'sangsu',
      file_path: 'lib/a.ml',
      line: 12,
      focus_mode: 'editing',
      turn: 7,
    })])
  })

  it('fetchIdeCursors rejects malformed cursor rows instead of dropping them', async () => {
    stubFetch({
      ok: true,
      data: {
        runtime_id: 'masc-runtime',
        connected: true,
        cursors: [{
          keeper_id: 'sangsu',
          file_path: 'lib/a.ml',
          line: 0,
          column: 3,
          focus_mode: 'editing',
          last_update: 1717400000000,
        }],
      },
    })

    await expect(fetchIdeCursors()).rejects.toThrow(
      'fetchIdeCursors returned malformed cursor rows',
    )
  })
})
