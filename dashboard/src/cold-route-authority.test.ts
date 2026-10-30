import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { RouteState } from './types'

const directRoutes: Pick<RouteState, 'tab' | 'params'>[] = [
  { tab: 'workspace', params: { section: 'artifacts', artifact: 'fixture-report' } },
  { tab: 'monitoring', params: { section: 'skills' } },
  { tab: 'monitoring', params: { section: 'lane-inventory' } },
  { tab: 'monitoring', params: { section: 'lane-addons' } },
  { tab: 'monitoring', params: { section: 'runtime', view: 'config' } },
  { tab: 'settings', params: { section: 'runtime' } },
  { tab: 'settings', params: { section: 'routing' } },
  { tab: 'settings', params: { section: 'paths' } },
  { tab: 'settings', params: { section: 'runtimes' } },
]

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

it.each(directRoutes)('obtains workspace authority on direct $tab/$params.section entry without visiting Work', async route => {
  const fetch = vi.fn(async (_input: string) => new Response(JSON.stringify(execution('/fixture/workspace')), {
    headers: { 'content-type': 'application/json' },
  }))
  vi.stubGlobal('fetch', fetch)
  const { executionWorkspaceAuthority } = await import('./store')
  const { refreshForRoute } = await import('./tab-refresh')
  expect(executionWorkspaceAuthority.peek()).toBeNull()

  refreshForRoute(route)
  await vi.advanceTimersByTimeAsync(300)
  await vi.waitFor(() => expect(executionWorkspaceAuthority.peek()?.workspaceRoot).toBe('/fixture/workspace'))
  expect(fetch.mock.calls.filter(([path]) => path === '/api/v1/dashboard/execution')).toHaveLength(1)
  const { dashboardSlicesForRoute } = await import('./dashboard-ws')
  expect(dashboardSlicesForRoute(route)).toContain('execution')
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
