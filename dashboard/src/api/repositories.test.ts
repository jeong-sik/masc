import { afterEach, describe, expect, it, vi } from 'vitest'
import { discoverRepositories, fetchRepositoriesList } from './repositories'

const mockFetch = vi.fn()

afterEach(() => {
  mockFetch.mockClear()
  vi.unstubAllGlobals()
})

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

describe('repositories API', () => {
  it('fetchRepositoriesList reads the configured repositories', async () => {
    stubFetch({
      repositories: [
        {
          id: 'masc',
          name: 'masc-mcp',
          local_path: '/Users/dancer/me/workspace/yousleepwhen/masc-mcp',
          status: 'active',
        },
      ],
    })

    const repos = await fetchRepositoriesList()

    expect(mockFetch.mock.calls[0]![0]).toBe('/api/v1/repositories')
    expect(repos).toHaveLength(1)
    expect(repos[0]!.id).toBe('masc')
    expect(repos[0]!.default_branch).toBe('main')
  })

  it('discoverRepositories registers discovered repositories through the backend', async () => {
    stubFetch({
      repositories: [
        {
          id: 'me',
          name: 'me',
          local_path: '/Users/dancer/me',
          status: 'active',
        },
      ],
      discovered: true,
      registered: true,
    })

    const repos = await discoverRepositories()
    const call = mockFetch.mock.calls[0]!
    const init = call[1] as RequestInit

    expect(call[0]).toBe('/api/v1/repositories/discover')
    expect(init.method).toBe('POST')
    expect(init.body).toBe(JSON.stringify({}))
    expect(repos).toHaveLength(1)
    expect(repos[0]!.id).toBe('me')
    expect(repos[0]!.local_path).toBe('/Users/dancer/me')
  })
})
