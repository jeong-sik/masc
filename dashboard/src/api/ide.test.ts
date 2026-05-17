import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  createIdeAnnotation,
  deleteIdeAnnotation,
  fetchIdeAnnotations,
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

  it('createIdeAnnotation appends workspace params to mutation URL', async () => {
    stubFetch({ ok: true, data: annotation })

    await createIdeAnnotation({
      file_path: 'lib/a.ml',
      line_start: 1,
      line_end: 1,
      keeper_id: 'sangsu',
      kind: 'Comment',
      content: 'Review this line',
    }, { keeper: 'sangsu', repoId: 'masc' })

    const url = String(mockFetch.mock.calls[0]![0])
    expect(url).toContain('/api/v1/ide/annotations?')
    expect(url).toContain('keeper=sangsu')
    expect(url).toContain('repo_id=masc')
  })

  it('fetchIdeRegions appends repo_id param', async () => {
    stubFetch({ ok: true, data: [region] })

    await fetchIdeRegions('lib/a.ml', { repoId: 'masc' })

    const url = String(mockFetch.mock.calls[0]![0])
    expect(url).toContain('/api/v1/ide/regions?')
    expect(url).toContain('file_path=lib%2Fa.ml')
    expect(url).toContain('repo_id=masc')
  })

  it('deleteIdeAnnotation appends repo_id param', async () => {
    stubFetch({}, true)

    await deleteIdeAnnotation('ann-1', 'sangsu', { repoId: 'masc' })

    const url = String(mockFetch.mock.calls[0]![0])
    expect(url).toContain('/api/v1/ide/annotations/ann-1?')
    expect(url).toContain('keeper_id=sangsu')
    expect(url).toContain('repo_id=masc')
  })
})
