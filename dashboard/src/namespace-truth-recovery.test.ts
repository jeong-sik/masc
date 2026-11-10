import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { parseSSEMessage } from './schemas/sse'

const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve() }
let dispose: (() => void) | undefined
beforeEach(() => { vi.resetModules(); vi.useFakeTimers() })
afterEach(() => {
  dispose?.(); dispose = undefined
  vi.unstubAllGlobals(); vi.restoreAllMocks(); vi.useRealTimers()
})

async function surface() {
  const actions = await import('./namespace-truth-actions')
  const state = await import('./namespace-truth-signals')
  const push = await import('./sse-store')
  dispose = actions.disposeNamespaceTruthScheduler
  const publish = () => {
    const event = parseSSEMessage({ type: 'project_snapshot', ts_unix: 1,
      payload: { root: { status: { project: 'ready', workspace_root: '/ready' } } } })
    if (event === null) throw new Error('canonical project snapshot was refused')
    push.hydrateServerPushEvent(event)
  }
  return { actions, state, publish }
}

describe('namespace initial and failed read debt', () => {
  it('waits after initializing and accepts producer completion with no status GET', async () => {
    const fetch = vi.fn().mockResolvedValue(new Response('{"status":"initializing"}', {
      headers: { 'content-type': 'application/json' },
    }))
    vi.stubGlobal('fetch', fetch)
    const { actions, state, publish } = await surface()
    await actions.refreshNamespaceTruth({ force: true })
    expect(state.namespaceTruthInitializing.value).toBe(true)
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    publish()
    expect(state.namespaceTruthInitializing.value).toBe(false)
    expect(state.namespaceTruth.value?.root.status?.project).toBe('ready')
    expect(state.namespaceTruthError.value).toBeNull()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it('retains actual failures beyond ten attempts and clears debt on canonical success', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    const fetch = vi.fn().mockRejectedValue(new Error('namespace offline'))
    vi.stubGlobal('fetch', fetch)
    const { actions, state, publish } = await surface()
    const { warmRetryDelayFor } = await import('./lib/warm-retry')
    await actions.refreshNamespaceTruth({ force: true })
    for (let attempt = 1; attempt <= 12; attempt++) {
      await vi.advanceTimersByTimeAsync(warmRetryDelayFor(attempt))
    }
    expect(fetch).toHaveBeenCalledTimes(13)
    expect(state.namespaceTruthError.value).toMatch(/namespace offline/)
    publish()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(13)
    expect(state.namespaceTruthError.value).toBeNull()
  })

  it('does not let a late HTTP failure erase a newer canonical snapshot', async () => {
    let fail!: (error: Error) => void
    const fetch = vi.fn().mockImplementation(() => new Promise<Response>((_resolve, reject) => { fail = reject }))
    vi.stubGlobal('fetch', fetch)
    const { actions, state, publish } = await surface()
    const read = actions.refreshNamespaceTruth({ force: true })
    await flush()
    expect(fetch).toHaveBeenCalledTimes(1)
    publish()
    fail(new Error('late old read'))
    await read
    expect(state.namespaceTruth.value?.root.status?.project).toBe('ready')
    expect(state.namespaceTruthError.value).toBeNull()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
  })
})
