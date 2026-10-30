import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { get, post } from '../api/core'
import { RepoDetailPanel, loadRepoDetail, loadRepoBranches } from './repo-detail-panel'
import { repositorySyncResults, selectedRepoId, syncRepository } from './repo-sidebar'

vi.mock('../api/core', () => ({ get: vi.fn(), post: vi.fn(), del: vi.fn() }))
vi.mock('./common/toast', () => ({ showToast: vi.fn() }))

afterEach(() => {
  cleanup()
  selectedRepoId.value = null
  repositorySyncResults.value = new Map()
})

describe('repository sync observation', () => {
  it('does not refresh the retired repository branches after selection changes during a sync detail read', async () => {
    let finishOld!: (value: unknown) => void
    let oldDetailReads = 0
    vi.mocked(get).mockClear().mockImplementation(async path => {
      if (path === '/api/v1/repositories/sync-a') {
        if (++oldDetailReads > 1) return new Promise(resolve => { finishOld = resolve })
        return { id: 'sync-a', name: 'Sync A', status: 'active' }
      }
      if (path === '/api/v1/repositories/sync-b') return { id: 'sync-b', name: 'Sync B', status: 'active' }
      if (path === '/api/v1/repositories/sync-a/branches') return [{ name: 'a-only' }]
      if (path === '/api/v1/repositories/sync-b/branches') return [{ name: 'b-only' }]
      throw new Error(`Unexpected request ${path}`)
    })
    await loadRepoDetail('sync-a')
    await loadRepoBranches('sync-a')
    selectedRepoId.value = 'sync-a'
    render(html`<${RepoDetailPanel} />`)
    vi.mocked(post).mockResolvedValue({ id: 'sync-a', status: 'active', advance: { state: 'already_current' } })
    fireEvent.click(screen.getByRole('button', { name: '지금 동기화' }))
    await waitFor(() => expect(oldDetailReads).toBe(2))
    await act(async () => { selectedRepoId.value = 'sync-b' })
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Sync B' })).toBeTruthy())
    await act(async () => {
      finishOld({ id: 'sync-a', name: 'Sync A', status: 'active' })
      await Promise.resolve()
    })
    await waitFor(() => expect(screen.getByRole('button', { name: '지금 동기화' }).hasAttribute('disabled')).toBe(false))
    expect(screen.getByText('b-only')).toBeTruthy()
    expect(vi.mocked(get).mock.calls.filter(([path]) => path === '/api/v1/repositories/sync-a/branches')).toHaveLength(1)
  })

  it('preserves the POST outcome if its follow-up detail read fails, including prototype-like IDs', async () => {
    const id = 'constructor'
    vi.mocked(get).mockResolvedValue({ id, name: 'Observed repository', status: 'active' })
    await loadRepoDetail(id)
    selectedRepoId.value = id
    render(html`<${RepoDetailPanel} />`)
    expect(screen.getByRole('heading', { name: 'Observed repository' })).toBeTruthy()
    expect(repositorySyncResults.value.get(id)).toBeUndefined()
    const advance = { state: 'fast_forward_refused', behind: 4, reason: 'remote-diverged-receipt' } as const
    vi.mocked(post).mockResolvedValue({ id, status: 'active', advance, branches: [] })
    await act(async () => { await syncRepository(id) })
    vi.mocked(get).mockRejectedValue(new Error('detail-read-unavailable'))
    await act(async () => { await loadRepoDetail(id) })
    expect(repositorySyncResults.value.get(id)).toEqual(advance)
    expect(screen.getByRole('status').textContent).toContain(advance.reason)
    expect(screen.getByText('detail-read-unavailable')).toBeTruthy()
  })

  it('retires an old repository read when a different selection is loaded', async () => {
    let finishOld!: (value: unknown) => void
    vi.mocked(get).mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve }))
    const old = loadRepoDetail('old-repository')
    vi.mocked(get).mockResolvedValue({ id: '__proto__', name: 'Current selection', status: 'active' })
    await loadRepoDetail('__proto__')
    selectedRepoId.value = '__proto__'
    render(html`<${RepoDetailPanel} />`)
    await act(async () => {
      finishOld({ id: 'old-repository', name: 'Retired selection', status: 'active' })
      await old
    })
    expect(screen.getByRole('heading', { name: 'Current selection' })).toBeTruthy()
    expect(screen.queryByRole('heading', { name: 'Retired selection' })).toBeNull()
    expect(repositorySyncResults.value.get('__proto__')).toBeUndefined()
  })
})
