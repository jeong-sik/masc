import { afterEach, describe, expect, it, vi } from 'vitest'
import { addRepository, discoverRepositories, fetchRepositoriesList, normalizeRepositoryGitStatus, removeRepository, requestRepositorySync, type RepositoryAdvanceOutcome } from './repositories'
import { repositorySyncResults, syncRepository } from '../components/repo-sidebar'
import { showToast } from '../components/common/toast'

vi.mock('../components/common/toast', () => ({ showToast: vi.fn() }))

const mockFetch = vi.fn()

afterEach(() => {
  mockFetch.mockClear()
  vi.unstubAllGlobals()
  vi.mocked(showToast).mockClear()
  repositorySyncResults.value = new Map()
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
  const advances: RepositoryAdvanceOutcome[] = [
    { state: 'advanced', behind: 3 }, { state: 'already_current' },
    { state: 'skipped_dirty', staged: 1, unstaged: 2, conflicted: 0 },
    { state: 'skipped_not_on_default_branch', current_branch: 'feature/work' },
    { state: 'fast_forward_refused', behind: 4, reason: 'diverged' },
    { state: 'advance_inspect_failed', reason: 'git unavailable' },
  ]

  it.each(advances)('retains the actual advance outcome through the action: $state', async advance => {
    stubFetch({ id: 'a/b', status: 'active', advance, branches: [] })
    expect(await syncRepository('a/b')).toEqual(advance)
    expect(repositorySyncResults.value.get('a/b')).toEqual(advance)
    expect(mockFetch).toHaveBeenCalledWith('/api/v1/repositories/a%2Fb/sync', expect.objectContaining({ method: 'POST' }))
    expect(showToast).toHaveBeenCalledWith(expect.any(String),
      advance.state === 'advanced' || advance.state === 'already_current' ? 'success' : 'warning')
  })

  it.each([
    {}, { state: 'unknown' }, { state: 'advanced', behind: -1 },
    { state: 'skipped_dirty', staged: 0, unstaged: 0 },
    { state: 'fast_forward_refused', behind: 3 },
  ])('rejects a malformed outcome without marking the sync successful: %j', async advance => {
    stubFetch({ id: 'repo', status: 'active', advance })
    await expect(syncRepository('repo')).rejects.toThrow('Malformed repository advance outcome')
    expect(repositorySyncResults.value.get('repo')).toBeUndefined()
    expect(showToast).toHaveBeenCalledWith(expect.any(String), 'error')
  })

  it('does not accept another repository as this sync result', async () => {
    stubFetch({ id: 'other', status: 'active', advance: { state: 'already_current' } })
    await expect(requestRepositorySync('repo')).rejects.toThrow('Malformed repository sync response')
  })

  it('fetchRepositoriesList reads the configured repositories', async () => {
    stubFetch({
      repositories: [
        {
          id: 'masc',
          name: 'masc',
          local_path: '/Users/worker/ws/workspace/yousleepwhen/masc',
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
          id: 'ws',
          name: 'ws',
          local_path: '/Users/worker/ws',
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
    expect(repos[0]!.id).toBe('ws')
    expect(repos[0]!.local_path).toBe('/Users/worker/ws')
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
