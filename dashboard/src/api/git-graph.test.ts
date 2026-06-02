import { afterEach, describe, expect, it, vi } from 'vitest'
import { fetchGitGraph } from './git-graph'

const mockFetch = vi.fn()

afterEach(() => {
  mockFetch.mockClear()
  vi.unstubAllGlobals()
})

function gitGraphPayload() {
  return {
    generated_at: '2026-05-05T00:00:00Z',
    repos: [],
    agents: [],
    nodes: [],
    edges: [],
    stats: {
      repo_count: 0,
      agent_count: 0,
      branch_count: 0,
      commit_count: 0,
      conflict_count: 0,
      dirty_count: 0,
    },
    warnings: [],
  }
}

function stubFetch(response: unknown): void {
  mockFetch.mockResolvedValue({
    ok: true,
    status: 200,
    statusText: 'OK',
    headers: new Headers(),
    json: () => Promise.resolve(response),
    text: () => Promise.resolve(JSON.stringify(response)),
    clone() { return this },
  } as Response)
  vi.stubGlobal('fetch', mockFetch)
}

describe('fetchGitGraph', () => {
  it('requests the default graph with a limit', async () => {
    stubFetch(gitGraphPayload())

    await fetchGitGraph({ limit: 160 })

    expect(mockFetch.mock.calls[0]![0]).toBe('/api/v1/git/graph?n=160')
  })

  it('appends repo_id when provided', async () => {
    stubFetch(gitGraphPayload())

    await fetchGitGraph({ limit: 160, repoId: 'masc' })

    expect(mockFetch.mock.calls[0]![0]).toBe('/api/v1/git/graph?n=160&repo_id=masc')
  })
})
