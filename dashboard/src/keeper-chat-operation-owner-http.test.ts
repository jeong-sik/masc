import { act } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, currentStoredTokenRevision, setStoredToken } from './api/core'
import { acceptedExecutionWorkspace } from './execution-workspace-authority'
import { resetDashboardSessionActorForTests, setCanonicalDashboardActor } from './lib/dashboard-session-actor'
import { publishDashboardObservationChange, publishDashboardObservationRecovery } from './lib/observation-refresh'
import { waitForKeeperChatOperationTerminal } from './keeper-chat-operation-observer'
import { _resetChatHydrationForTests, hydrateTrackedKeeperChatOperations } from './keeper-actions'
import { _clearTrackedKeeperChatOperationsForTests, trackedKeeperChatOperationsForKeeper,
  upsertTrackedKeeperChatOperation } from './keeper-chat-operations-local'
import { keeperActionErrors } from './keeper-state'

const disposers: Array<() => void> = []
const settle = () => act(async () => { await vi.advanceTimersByTimeAsync(0) })
const pendingOperation = () => Response.json({ schema: 'masc.keeper_chat_operation.v1', operation_id: 'original',
  sequence: '1', created_at: 1, input: null, state: 'Running', started_at: 1 })
function workspace() {
  acceptedExecutionWorkspace.value = { epoch: 'operation-A', workspaceRoot: '/workspace-A',
    connectionGeneration: 1, observerInstanceId: 'operation-instance-A' }
}
beforeEach(() => {
  vi.useFakeTimers()
  resetDashboardSessionActorForTests()
  setStoredToken('operation-credential-A', { source: 'manual' })
  workspace()
  _resetChatHydrationForTests()
  _clearTrackedKeeperChatOperationsForTests()
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
})
afterEach(async () => {
  for (const dispose of disposers.splice(0)) dispose()
  _resetChatHydrationForTests()
  _clearTrackedKeeperChatOperationsForTests()
  acceptedExecutionWorkspace.value = null
  clearStoredToken()
  resetDashboardSessionActorForTests()
  await settle()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})
describe('original durable operation HTTP owner', () => {
  it('retires the actual tracked hydration without recording an old actor failure or reading history as the new actor', async () => {
    const fetch = vi.fn(async (path: string, options?: RequestInit) => {
      expect(path).toBe('/api/v1/keepers/keeper/chat/operations/original')
      expect(options?.method ?? 'GET').toBe('GET')
      return pendingOperation()
    })
    vi.stubGlobal('fetch', fetch)
    upsertTrackedKeeperChatOperation({ operationId: 'original', keeperName: 'keeper', message: 'retained input', submittedAt: 1 })
    let settled = false
    const hydration = hydrateTrackedKeeperChatOperations('keeper').then(() => { settled = true })
    await settle()
    expect(fetch).toHaveBeenCalledTimes(1)
    await act(async () => { setCanonicalDashboardActor('actor-B') })
    await settle()
    expect(settled).toBe(true)
    await hydration
    expect(keeperActionErrors.value.keeper ?? null).toBeNull()
    expect(trackedKeeperChatOperationsForKeeper('keeper').map(request => request.operationId)).toEqual(['original'])
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it.each(['unknown-workspace', 'actor'] as const)('settles the original waiter when its %s owner is retired, without another operation read', async changed => {
    const fetch = vi.fn(async (_path: string, _options?: RequestInit) => pendingOperation())
    vi.stubGlobal('fetch', fetch)
    const authority = acceptedExecutionWorkspace.peek()
    const credential = currentStoredTokenRevision()
    // The two production callers already supplied this exact older guard.
    const waiter = waitForKeeperChatOperationTerminal('keeper', 'original', {
      current: () => acceptedExecutionWorkspace.peek() === authority && currentStoredTokenRevision() === credential,
    })
    disposers.push(waiter.dispose)
    let failure: unknown = null
    void waiter.result.catch(cause => { failure = cause })
    await settle()
    expect(fetch).toHaveBeenCalledTimes(1)
    await act(async () => {
      if (changed === 'unknown-workspace') acceptedExecutionWorkspace.value = null
      else setCanonicalDashboardActor('actor-B')
    })
    await settle()
    expect(failure).toMatchObject({ name: 'AbortError' })
    publishDashboardObservationChange({ topic: 'chat_operation', keeperName: 'keeper', operationId: 'original' })
    publishDashboardObservationRecovery()
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(fetch.mock.calls.every(([_path, options]) => options?.method === undefined || options.method === 'GET')).toBe(true)
  })
})
