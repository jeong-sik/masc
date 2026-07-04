import { afterEach, describe, expect, it, vi } from 'vitest'
import { addRepository, discoverRepositories, fetchRepositoriesList, normalizeRepositoryGitStatus, removeRepository } from './repositories'

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
          name: 'masc',
          local_path: '/Users/dancer/me/workspace/yousleepwhen/masc',
          status: 'active',
          git_status: {
            state: 'available',
            source: 'git-status-porcelain-v1',
            dirty: true,
            changed_files: 3,
            staged_files: 1,
            unstaged_files: 1,
            untracked_files: 1,
            conflicted_files: 0,
          },
        },
      ],
    })

    const repos = await fetchRepositoriesList()

    expect(mockFetch.mock.calls[0]![0]).toBe('/api/v1/repositories')
    expect(repos).toHaveLength(1)
    expect(repos[0]!.id).toBe('masc')
    expect(repos[0]!.default_branch).toBe('main')
    expect(repos[0]!.git_status).toMatchObject({
      state: 'available',
      changed_files: 3,
      staged_files: 1,
      unstaged_files: 1,
      untracked_files: 1,
    })
  })

  it('does not silently coerce malformed git_status to a clean tree', () => {
    expect(normalizeRepositoryGitStatus({
      state: 'available',
      dirty: true,
      changed_files: '3',
    })).toEqual({
      state: 'unavailable',
      source: '',
      error: 'malformed repository git_status payload',
    })
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

  it('addRepository posts the registration payload as-is', async () => {
    stubFetch({ ok: true })

    await addRepository({
      name: 'my-project',
      url: 'https://github.com/o/r.git',
      default_branch: 'develop',
      auto_sync: false,
      sync_interval: 600,
    })

    const call = mockFetch.mock.calls[0]!
    const init = call[1] as RequestInit
    expect(call[0]).toBe('/api/v1/repositories')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      name: 'my-project',
      url: 'https://github.com/o/r.git',
      default_branch: 'develop',
      auto_sync: false,
      sync_interval: 600,
    })
  })

  it('removeRepository deletes by URL-encoded id', async () => {
    stubFetch({ ok: true })

    await removeRepository('repo id/with slash')

    const call = mockFetch.mock.calls[0]!
    const init = call[1] as RequestInit
    expect(call[0]).toBe('/api/v1/repositories/repo%20id%2Fwith%20slash')
    expect(init.method).toBe('DELETE')
  })
})
