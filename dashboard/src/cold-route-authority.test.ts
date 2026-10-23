import { afterEach, beforeEach, expect, it, vi } from 'vitest'

beforeEach(() => { vi.resetModules(); vi.useFakeTimers() })
afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); vi.resetModules() })

function execution(workspaceRoot: string | null) {
  return {
    generated_at: '2026-10-23T00:00:00Z',
    execution_publication_epoch: 'cold-route-fixture',
    execution_publication_generation: 1,
    status: { project: 'fixture', workspace_root: workspaceRoot },
    agents: [], tasks: [], messages: [], keepers: [],
  }
}

it('obtains workspace authority on a direct artifact route without visiting Work', async () => {
  const fetch = vi.fn(async (_input: string) => new Response(JSON.stringify(execution('/fixture/workspace')), {
    headers: { 'content-type': 'application/json' },
  }))
  vi.stubGlobal('fetch', fetch)
  const { executionWorkspaceAuthority } = await import('./store')
  const { refreshForRoute } = await import('./tab-refresh')
  expect(executionWorkspaceAuthority.peek()).toBeNull()

  refreshForRoute({ tab: 'workspace', params: { section: 'artifacts', artifact: 'fixture-report' } })
  await vi.advanceTimersByTimeAsync(300)
  await vi.waitFor(() => expect(executionWorkspaceAuthority.peek()?.workspaceRoot).toBe('/fixture/workspace'))
  expect(fetch).toHaveBeenCalledTimes(1)
  expect(fetch.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/execution')
})

it('keeps artifact access unverified when the execution response lacks a workspace', async () => {
  const fetch = vi.fn(async (_input: string) => new Response(JSON.stringify(execution(null)), {
    headers: { 'content-type': 'application/json' },
  }))
  vi.stubGlobal('fetch', fetch)
  const { executionWorkspaceAuthority, executionLoaded } = await import('./store')
  const { refreshForRoute } = await import('./tab-refresh')

  refreshForRoute({ tab: 'workspace', params: { section: 'artifacts' } })
  await vi.advanceTimersByTimeAsync(300)
  await vi.waitFor(() => expect(executionLoaded.peek()).toBe(true))
  expect(executionWorkspaceAuthority.peek()).toBeNull()
})
