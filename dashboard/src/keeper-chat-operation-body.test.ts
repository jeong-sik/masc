import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { DEFAULT_GET_TIMEOUT_MS, clearStoredToken, setStoredToken } from './api/core'
import { fetchKeeperChatOperation } from './api/keeper'
import { acceptedExecutionWorkspace } from './execution-workspace-authority'
import { setCanonicalDashboardActor, resetDashboardSessionActorForTests } from './lib/dashboard-session-actor'
import { waitForKeeperChatOperationTerminal } from './keeper-chat-operation-observer'

const releases: Array<() => void> = []
function pendingBody() {
  let source!: ReadableStreamDefaultController<Uint8Array>
  let open = true
  let signal!: AbortSignal
  const fail = () => {
    if (open) { open = false; source.error(new DOMException('Body transport aborted', 'AbortError')) }
  }
  const stream = new ReadableStream<Uint8Array>({ start(controller) { source = controller } })
  const fetch = vi.fn(async (path: string, options: RequestInit) => {
    expect(path).toBe('/api/v1/keepers/keeper/chat/operations/original')
    signal = options.signal as AbortSignal
    signal.addEventListener('abort', fail, { once: true })
    return new Response(stream, { status: 200 })
  })
  vi.stubGlobal('fetch', fetch)
  releases.push(() => { signal?.removeEventListener('abort', fail); fail() })
  return { fetch, signal: () => signal }
}
beforeEach(() => {
  vi.useFakeTimers()
  resetDashboardSessionActorForTests()
  setStoredToken('original-operation-body-credential', { source: 'manual' })
  acceptedExecutionWorkspace.value = { epoch: 'body-owner', workspaceRoot: '/workspace',
    connectionGeneration: 1, observerInstanceId: 'body-instance' }
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
})
afterEach(async () => {
  for (const release of releases.splice(0)) release()
  acceptedExecutionWorkspace.value = null
  clearStoredToken()
  resetDashboardSessionActorForTests()
  await vi.advanceTimersByTimeAsync(0)
  vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals()
})
describe('original operation shared GET body boundary', () => {
  it('expires an original operation lookup whose headers arrive without JSON body bytes', async () => {
    const transport = pendingBody()
    const done = fetchKeeperChatOperation('keeper', 'original').catch(cause => cause)
    await vi.advanceTimersByTimeAsync(0)
    expect(transport.signal().aborted).toBe(false)
    await vi.advanceTimersByTimeAsync(DEFAULT_GET_TIMEOUT_MS)
    expect(transport.signal().aborted).toBe(true)
    expect(await done).toMatchObject({ method: 'GET', path: '/api/v1/keepers/keeper/chat/operations/original', timeout: true })
    expect(transport.fetch).toHaveBeenCalledTimes(1)
  })
  it('physically aborts a quiet original operation body when its actor owner is retired', async () => {
    const transport = pendingBody()
    const waiter = waitForKeeperChatOperationTerminal('keeper', 'original')
    releases.push(waiter.dispose)
    const done = waiter.result.catch(cause => cause)
    await vi.advanceTimersByTimeAsync(0)
    setCanonicalDashboardActor('replacement-actor')
    expect(await done).toMatchObject({ name: 'AbortError' })
    expect(transport.signal().aborted).toBe(true)
    expect(transport.fetch).toHaveBeenCalledTimes(1)
  })
})
