import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { parseSSEMessage } from './schemas/sse'

const json = (body: unknown) => new Response(JSON.stringify(body), {
  headers: { 'content-type': 'application/json' },
})
const complete = { read_completeness: 'complete', read_error: null }
const partial = { read_completeness: 'partial', read_error: 'original source read failed' }
const execution = (project: string, generation = 1, diagnostics: Record<string, unknown> = complete) => ({
  observer_instance_id: 'projection-workspace', execution_publication_epoch: 'projection-process',
  execution_publication_generation: generation, generated_at: '2026-11-10T00:00:00Z',
  projection_diagnostics: diagnostics, status: { project, workspace_root: '/projection-workspace' },
  agents: [], tasks: [], keepers: [], messages: [],
})
const namespace = (project: string, diagnostics: Record<string, unknown> = complete) => ({
  observer_instance_id: 'projection-workspace', projection_diagnostics: diagnostics,
  root: { status: { project, workspace_root: '/projection-workspace' } },
})
const flush = async () => { for (let i = 0; i < 40; i++) await Promise.resolve() }
const disposals: Array<() => void> = []

beforeEach(() => {
  vi.resetModules(); vi.useFakeTimers(); localStorage.clear(); sessionStorage.clear()
  vi.spyOn(console, 'warn').mockImplementation(() => {})
})
afterEach(async () => {
  for (const dispose of disposals.splice(0)) dispose()
  await flush()
  vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals()
})

async function surface() {
  const store = await import('./store')
  const actions = await import('./namespace-truth-actions')
  const state = await import('./namespace-truth-signals')
  const push = await import('./sse-store')
  disposals.push(store.disposeExecutionReadRecovery, actions.disposeNamespaceTruthScheduler)
  const publish = (type: 'execution_snapshot' | 'project_snapshot', payload: unknown) => {
    const event = parseSSEMessage({ type, ts_unix: 1, payload })
    if (event === null) throw new Error('actual projection event was refused')
    push.hydrateServerPushEvent(event)
  }
  return { store, actions, state, publish }
}

describe('partial projection outcomes through HTTP and the real SSE dispatcher', () => {
  it('waits for real canonical bodies after an initializing bootstrap without fallback GETs', async () => {
    const fetch = vi.fn().mockResolvedValue(json({
      shell: { status: { project: 'booting' }, counts: {}, providers: {} },
      execution: { status: 'initializing' }, namespace_truth: { status: 'initializing' },
    }))
    vi.stubGlobal('fetch', fetch)
    const { store, state, publish } = await surface()
    await store.refreshDashboard({ force: true })
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(store.executionLoaded.value).toBe(false)
    expect(store.executionWorkspaceAuthority.peek()).toBeNull()
    expect(state.namespaceTruthInitializing.value).toBe(true)
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    publish('execution_snapshot', execution('ready'))
    publish('project_snapshot', namespace('ready'))
    expect(store.executionLoaded.value).toBe(true)
    expect(state.namespaceTruthInitializing.value).toBe(false)
    expect(state.namespaceTruthError.value).toBeNull()
    expect(vi.getTimerCount()).toBe(0)
  })

  it('fences older Namespace HTTP success when bootstrap has accepted an actual partial body', async () => {
    let resolve!: (value: Response) => void
    const held = new Promise<Response>(yes => { resolve = yes })
    const fetch = vi.fn((path: string) => path.includes('/bootstrap')
      ? Promise.resolve(json({ shell: { status: {}, counts: {}, providers: {} }, execution: execution('current'),
          namespace_truth: namespace('bootstrap partial', partial) })) : held)
    vi.stubGlobal('fetch', fetch)
    const { store, actions, state, publish } = await surface()
    const older = actions.refreshNamespaceTruth({ force: true })
    await flush()
    await store.refreshDashboard({ force: true })
    expect(state.namespaceTruth.value?.root.status?.project).toBe('bootstrap partial')
    expect(state.namespaceTruthError.value).toBe(partial.read_error)
    resolve(json(namespace('older complete')))
    await older
    expect(state.namespaceTruth.value?.root.status?.project).toBe('bootstrap partial')
    expect(state.namespaceTruthError.value).toBe(partial.read_error)
    publish('project_snapshot', namespace('canonical repair'))
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(state.namespaceTruth.value?.root.status?.project).toBe('canonical repair')
    expect(state.namespaceTruthError.value).toBeNull()
    expect(vi.getTimerCount()).toBe(0)
  })

  it('keeps a same-generation canonical Execution completion when an older bootstrap returns partial', async () => {
    let resolve!: (value: Response) => void
    const fetch = vi.fn().mockReturnValue(new Promise<Response>(yes => { resolve = yes }))
    vi.stubGlobal('fetch', fetch)
    const { store, publish } = await surface()
    const body = (agent: string, diagnostics: Record<string, unknown> = complete) => ({ ...execution('same-project', 1, diagnostics),
      candle_observation_sequence: 5, agents: [{ name: agent, status: 'active' }] })
    publish('execution_snapshot', body('original-agent'))
    const older = store.refreshDashboard({ force: true })
    await flush()
    expect(fetch).toHaveBeenCalledTimes(1)
    publish('execution_snapshot', body('canonical-agent'))
    resolve(json({ shell: { status: { project: 'same-project' }, counts: {}, providers: {} },
      execution: { ...body('older-bootstrap-agent', partial), query: { default_light_request: true } } }))
    await older
    expect(store.agents.value.map(agent => agent.name)).toEqual(['canonical-agent'])
    expect(store.executionError.value).toBeNull()
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('retains Execution partial rows and its exact failure until a quiet HTTP repair', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(json(execution('partial rows', 1, partial)))
      .mockResolvedValue(json(execution('repaired', 2)))
    vi.stubGlobal('fetch', fetch)
    const { store } = await surface()
    await store.refreshExecution({ force: true })
    expect(store.serverStatus.value?.project).toBe('partial rows')
    expect(store.executionError.value).toBe(partial.read_error)
    expect(store.executionWorkspaceAuthority.peek()?.observerInstanceId).toBe('projection-workspace')
    await vi.advanceTimersByTimeAsync(3_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(store.serverStatus.value?.project).toBe('repaired')
    expect(store.executionError.value).toBeNull()
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('lets a canonical Execution partial body own debt and its completion cancel HTTP retry', async () => {
    const fetch = vi.fn().mockResolvedValue(json(execution('private partial', 1, partial)))
    vi.stubGlobal('fetch', fetch)
    const { store, publish } = await surface()
    await store.refreshExecution({ force: true })
    publish('execution_snapshot', execution('canonical partial', 2, partial))
    expect(store.serverStatus.value?.project).toBe('canonical partial')
    expect(store.executionError.value).toBe(partial.read_error)
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    publish('execution_snapshot', execution('canonical complete', 3))
    expect(store.executionError.value).toBeNull()
    expect(store.serverStatus.value?.project).toBe('canonical complete')
    expect(vi.getTimerCount()).toBe(0)
  })

  it('waits for the Execution producer after a default canonical HTTP partial response', async () => {
    const fetch = vi.fn().mockResolvedValue(json({ ...execution('canonical HTTP partial', 1, partial),
      query: { actor: null, fixture: null, full: false, light: true, default_light_request: true, force: false } }))
    vi.stubGlobal('fetch', fetch)
    const { store, publish } = await surface()
    await store.refreshExecution({ immediate: true })
    expect(store.executionError.value).toBe(partial.read_error)
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    publish('execution_snapshot', execution('repaired producer', 2))
    expect(store.executionError.value).toBeNull()
    expect(vi.getTimerCount()).toBe(0)
  })

  it('retains Namespace partial rows and its exact failure until a quiet HTTP repair', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(json(namespace('partial namespace', partial)))
      .mockResolvedValue(json(namespace('repaired namespace')))
    vi.stubGlobal('fetch', fetch)
    const { actions, state } = await surface()
    await actions.refreshNamespaceTruth({ force: true })
    expect(state.namespaceTruth.value?.root.status?.project).toBe('partial namespace')
    expect(state.namespaceTruthError.value).toBe(partial.read_error)
    await vi.advanceTimersByTimeAsync(3_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(state.namespaceTruth.value?.root.status?.project).toBe('repaired namespace')
    expect(state.namespaceTruthError.value).toBeNull()
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('lets canonical Namespace partial and complete bodies settle read debt with zero GETs', async () => {
    const fetch = vi.fn().mockResolvedValue(json(namespace('private partial', partial)))
    vi.stubGlobal('fetch', fetch)
    const { actions, state, publish } = await surface()
    await actions.refreshNamespaceTruth({ force: true })
    publish('project_snapshot', namespace('canonical partial', partial))
    expect(state.namespaceTruth.value?.root.status?.project).toBe('canonical partial')
    expect(state.namespaceTruthError.value).toBe(partial.read_error)
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    publish('project_snapshot', namespace('canonical complete'))
    expect(state.namespaceTruthError.value).toBeNull()
    expect(state.namespaceTruth.value?.root.status?.project).toBe('canonical complete')
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each(['execution', 'namespace'] as const)('keeps advancing %s partial-read backoff until a canonical repair', async kind => {
    const fetch = vi.fn().mockImplementation(() => Promise.resolve(json(kind === 'execution'
      ? execution('partial', 1, partial) : namespace('partial', partial))))
    vi.stubGlobal('fetch', fetch)
    const { store, actions, publish } = await surface()
    if (kind === 'execution') await store.refreshExecution({ force: true })
    else await actions.refreshNamespaceTruth({ force: true })
    const { warmRetryDelayFor } = await import('./lib/warm-retry')
    await vi.advanceTimersByTimeAsync(warmRetryDelayFor(1))
    expect(fetch).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(warmRetryDelayFor(2) - 1)
    expect(fetch).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetch).toHaveBeenCalledTimes(3)
    if (kind === 'execution') publish('execution_snapshot', execution('repaired', 2))
    else publish('project_snapshot', namespace('repaired'))
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(3)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('rejects an old HTTP partial after a same-generation canonical Execution completion', async () => {
    let resolve!: (value: Response) => void
    const fetch = vi.fn().mockReturnValue(new Promise<Response>(yes => { resolve = yes }))
    vi.stubGlobal('fetch', fetch)
    const { store, publish } = await surface()
    const request = store.refreshExecution({ force: true })
    const superseded = expect(request).rejects.toThrow('superseded')
    await flush()
    expect(fetch).toHaveBeenCalledTimes(1)
    publish('execution_snapshot', execution('canonical completion', 1))
    resolve(json(execution('old partial', 1, partial)))
    await superseded
    expect(store.serverStatus.value?.project).toBe('canonical completion')
    expect(store.executionError.value).toBeNull()
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each([
    {}, { read_completeness: 'unknown', read_error: null },
    { read_completeness: 'complete', read_error: 'contradictory read error' },
  ])('refuses an Execution HTTP body with invalid observed diagnostics %o', async diagnostics => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json({ ...execution('invalid'), projection_diagnostics: diagnostics })))
    const { store } = await surface()
    await expect(store.refreshExecution({ force: true })).rejects.toThrow()
    expect(store.executionLoaded.value).toBe(false)
    expect(store.executionError.value).toBeTruthy()
    expect(store.executionWorkspaceAuthority.peek()).toBeNull()
  })

  it.each([
    {}, { read_completeness: 'unknown', read_error: null },
    { read_completeness: 'complete', read_error: 'contradictory read error' },
  ])('refuses a Namespace HTTP body with invalid observed diagnostics %o', async diagnostics => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json({ ...namespace('invalid'), projection_diagnostics: diagnostics })))
    const { actions, state } = await surface()
    await actions.refreshNamespaceTruth({ force: true })
    expect(state.namespaceTruth.value).toBeNull()
    expect(state.namespaceTruthError.value).toBeTruthy()
  })
})
