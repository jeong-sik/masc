import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const effects = vi.hoisted(() => ({ toast: vi.fn(), recoverCredential: vi.fn(async () => {}) }))
vi.mock('./components/common/toast', () => ({ showToast: effects.toast }))
vi.mock('./api/dev-token', async original => ({
  ...(await original<typeof import('./api/dev-token')>()),
  recoverFromRejectedCredential: effects.recoverCredential,
}))

const completeRead = { read_completeness: 'complete', read_error: null }
const flush = async () => { for (let i = 0; i < 24; i++) await Promise.resolve() }
const json = (body: unknown) => new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json' } })
const item = (path: string) => ({ path, source: 'workspace', exists: true })
function shell(version = 'first') {
  return {
    status: { project: version, workspace_root: '/workspace' },
    counts: { agents: 1, keepers: 2, tasks: 3 }, configured_keepers: 4,
    auth: { enabled: false, require_token: false, token_present: false, token_valid: false },
    config_resolution: { status: 'ready', config_root: item(version), prompts: item(version), keepers: item(version) },
    runtime_resolution: {
      status: 'ready', base_path: item(version), workspace_path: item(version),
      resolved_base_path: item(version), data_root: item(version), prompt_markdown_dir: item(version),
      build: { release_version: '1', started_at: '2026-11-10T00:00:00Z', uptime_seconds: 0 },
    },
  }
}
function execution(generation = 1) {
  return {
    observer_instance_id: 'shell-A', execution_publication_epoch: 'shell-process', execution_publication_generation: generation,
    generated_at: '2026-11-10T00:00:00Z',
    status: { project: 'fixture-project', workspace_root: '/workspace' },
    projection_diagnostics: { read_completeness: 'complete', read_error: null },
    tasks: [{ id: 'task-bootstrap-observation', title: `execution-body-${generation}`, status: 'todo' }],
  }
}
function delayed() {
  let resolve!: (value: Response) => void
  let reject!: (error: Error) => void
  const promise = new Promise<Response>((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}

let stop: (() => void) | undefined
let store: typeof import('./store') | undefined
let namespaceActions: typeof import('./namespace-truth-actions') | undefined
beforeEach(() => {
  vi.resetModules(); vi.useFakeTimers(); sessionStorage.clear(); localStorage.clear()
  vi.spyOn(console, 'warn').mockImplementation(() => {})
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
})
afterEach(async () => {
  stop?.(); stop = undefined
  namespaceActions?.disposeNamespaceTruthScheduler(); namespaceActions = undefined
  store?.disposeExecutionReadRecovery(); store = undefined
  await flush()
  vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals(); vi.clearAllMocks()
})
async function surface(acceptWorkspace = true) {
  const workspace = await import('./execution-workspace-authority')
  if (acceptWorkspace) workspace.acceptedExecutionWorkspace.value = Object.freeze({
    epoch: 'shell-process', workspaceRoot: '/workspace', connectionGeneration: 1, observerInstanceId: 'shell-A',
  })
  store = await import('./store')
  const observation = await import('./lib/observation-refresh')
  stop = store.setupShellObservation()
  return { store, observation, workspace }
}

describe('App-owned Shell observation', () => {
  it('does not read an unknown workspace and reads an accepted owner only once', async () => {
    const fetch = vi.fn().mockResolvedValue(json(shell()))
    vi.stubGlobal('fetch', fetch)
    const { observation, workspace } = await surface(false)
    observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    window.dispatchEvent(new Event('focus'))
    observation.publishDashboardObservationRecovery()
    await flush()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).not.toHaveBeenCalled()
    workspace.acceptedExecutionWorkspace.value = Object.freeze({
      epoch: 'accepted-process', workspaceRoot: '/workspace', connectionGeneration: 1, observerInstanceId: 'shell-B',
    })
    await flush()
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each([401, 403])('retains HTTP %s refusal across source/focus/recovery until its actual token changes', async status => {
    const fetch = vi.fn().mockResolvedValueOnce(new Response('{"error":"forbidden"}', { status }))
      .mockResolvedValue(json(shell('replacement')))
    vi.stubGlobal('fetch', fetch)
    const { store, observation } = await surface()
    const api = await import('./api/dashboard-hot')
    const actualRead = api.fetchDashboardShell
    let originalCause: unknown
    vi.spyOn(api, 'fetchDashboardShell').mockImplementation(options => actualRead(options).catch(cause => {
      originalCause = cause
      throw cause
    }))
    const retain = vi.spyOn(observation, 'retainObservationReadFailure')
    observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    await flush()
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(originalCause).toBeInstanceOf((await import('./api/core')).ApiRequestError)
    expect(retain).toHaveBeenCalledWith(originalCause)
    expect(store.shellAuthSummary.value).toBeNull()
    for (let i = 0; i < 3; i++) {
      observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
      window.dispatchEvent(new Event('focus'))
      observation.publishDashboardObservationRecovery()
      await flush()
    }
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
    const { setStoredToken } = await import('./api/core')
    setStoredToken('replacement')
    // The production global push recovery calls this after the helper's
    // owner listener. Both paths owe the same new-owner read.
    store.recoverShellReadDebt(true)
    await flush()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(store.serverStatus.value?.project).toBe('replacement')
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each([401, 403])('keeps a managed HTTP %s cause without inventing a new header owner', async status => {
    const core = await import('./api/core')
    const actor = await import('./lib/dashboard-session-actor')
    const ownership = await import('./lib/observation-read-owner')
    core.setStoredToken('managed', { source: 'dev', actor: 'dashboard', role: 'admin' })
    actor.setCanonicalDashboardActor('dashboard')
    const rejected = vi.fn()
    core.setRejectedCredentialListener(rejected)
    const fetch = vi.fn().mockResolvedValue(new Response('{"auth_error_code":"invalid_token"}', { status }))
    vi.stubGlobal('fetch', fetch)
    const { store, observation } = await surface()
    const headerOwner = ownership.captureDashboardObservationOwner()
    const strictOwner = core.captureDashboardCredentialOwner()
    observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    await flush()
    expect(ownership.dashboardObservationOwnerIsCurrent(headerOwner)).toBe(true)
    expect(actor.currentCanonicalDashboardActor()).toBe('dashboard')
    if (status === 401) {
      expect(core.dashboardCredentialOwnerIsCurrent(strictOwner)).toBe(false)
      expect(rejected).toHaveBeenCalledTimes(1)
    }
    observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    window.dispatchEvent(new Event('focus'))
    observation.publishDashboardObservationRecovery()
    await flush()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(store.shellAuthSummary.value).toBeNull()
    expect(effects.toast).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
    core.setRejectedCredentialListener(null)
  })

  it('waits without a timer after a successful pending read and accepts the next source read', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(json(shell('initializing'))).mockResolvedValue(json(shell('ready')))
    vi.stubGlobal('fetch', fetch)
    const { store, observation } = await surface()
    observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    await flush()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
    observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    await flush()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(store.serverStatus.value?.project).toBe('ready')
    expect(vi.getTimerCount()).toBe(0)
  })

  it('subscribes without a boot read, then refreshes full config/runtime once per owed source change', async () => {
    const held = delayed()
    const fetch = vi.fn().mockResolvedValueOnce(json(shell())).mockImplementationOnce(() => held.promise)
      .mockResolvedValue(json(shell('latest')))
    vi.stubGlobal('fetch', fetch)
    const { store, observation } = await surface()
    await flush()
    expect(fetch).not.toHaveBeenCalled()
    expect(await store.refreshShell({ light: true })).toBe(true)
    observation.publishDashboardObservationChange({ topic: 'logs' })
    await flush()
    expect(fetch).toHaveBeenCalledTimes(1)
    const { receiveDashboardObserverEvent } = await import('./dashboard-observer')
    receiveDashboardObserverEvent({ type: 'workspace_dataset_changed', dataset: 'dashboard_observation',
      topic: 'runtime_resolved', scope: 'workspace' })
    await flush()
    expect(fetch.mock.calls[1]?.[0]).toBe('/api/v1/dashboard/shell')
    observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    held.resolve(json(shell('middle')))
    await flush(); await flush()
    expect(fetch).toHaveBeenCalledTimes(3)
    expect(store.shellConfigResolution.value?.config_root.path).toBe('latest')
    expect(store.shellRuntimeResolution.value?.base_path.path).toBe('latest')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(3)
  })

  it.each(['shell', 'bootstrap'] as const)('keeps canonical root counts when an older %s HTTP completes later', async kind => {
    const held = delayed()
    const fetch = vi.fn((_path: string, _init?: RequestInit) => held.promise)
    vi.stubGlobal('fetch', fetch)
    const { store } = await surface()
    const pending = kind === 'shell' ? store.refreshShell({ force: true }) : store.refreshDashboard({ force: true })
    await flush()
    const { hydrateServerPushEvent } = await import('./sse-store')
    hydrateServerPushEvent({ type: 'project_snapshot', payload: { projection_diagnostics: completeRead, root: {
      status: { project: 'canonical', workspace_root: '/workspace' },
      counts: { agents: 5, tasks: 9, keepers: 7 }, configured_keepers: 13,
    } } })
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(store.shellCounts.value).toEqual({ agents: 5, tasks: 9, keepers: 7, total_runtimes: 12, configured_keepers: 13 })
    const old = shell('old-http')
    held.resolve(json(kind === 'shell' ? old : { shell: old, execution: { projection_diagnostics: completeRead }, namespace_truth: { projection_diagnostics: completeRead, root: old } }))
    await pending
    expect(store.serverStatus.value?.project).toBe('canonical')
    expect(store.shellCounts.value?.tasks).toBe(9)
    expect(store.shellCounts.value?.configured_keepers).toBe(13)
    expect(store.shellAuthSummary.value).not.toBeNull()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it.each([
    ['shell', 'namespace-first'], ['shell', 'shell-first'],
    ['bootstrap', 'namespace-first'], ['bootstrap', 'shell-first'],
  ] as const)('keeps accepted namespace HTTP counts across an older %s response with %s delivery', async (kind, order) => {
    const older = delayed(), namespace = delayed()
    const fetch = vi.fn((path: string, _init?: RequestInit) => path === '/api/v1/dashboard/project-snapshot' ? namespace.promise : older.promise)
    vi.stubGlobal('fetch', fetch)
    const { store } = await surface()
    stop?.(); stop = undefined
    store.hydrateExecutionSnapshot(execution())
    const owner = store.executionWorkspaceAuthority.peek()
    const pending = kind === 'shell' ? store.refreshShell({ force: true }) : store.refreshDashboard({ force: true })
    await flush()
    namespaceActions = await import('./namespace-truth-actions')
    const namespaceRead = namespaceActions.refreshNamespaceTruth({ force: true })
    await flush()
    expect(fetch.mock.calls.map(([path]) => path)).toEqual([
      kind === 'shell' ? '/api/v1/dashboard/shell' : '/api/v1/dashboard/bootstrap',
      '/api/v1/dashboard/project-snapshot',
    ])
    const old = { ...shell('older-shell'), status: {
      project: 'fixture-project', workspace_root: '/workspace', generated_at: '2026-11-10T00:00:00Z',
    } }
    const current = { ...shell('accepted-namespace'), status: {
      project: 'fixture-project', workspace_root: '/workspace', generated_at: '2026-11-10T00:00:01Z',
    }, counts: { agents: 5, tasks: 9, keepers: 7 }, configured_keepers: 13 }
    const acceptOlder = async () => {
      older.resolve(json(kind === 'shell' ? old : { shell: old, execution: execution(2), namespace_truth: { projection_diagnostics: completeRead, root: old } }))
      const result = await pending
      if (kind === 'shell') expect(result).toBe(true)
    }
    const acceptNamespace = async () => {
      namespace.resolve(json({ projection_diagnostics: completeRead, root: current }))
      await namespaceRead
    }
    if (order === 'namespace-first') {
      await acceptNamespace()
      expect(store.shellCounts.value?.tasks).toBe(9)
      await acceptOlder()
    } else {
      await acceptOlder()
      await acceptNamespace()
    }
    expect(store.serverStatus.value?.generated_at).toBe('2026-11-10T00:00:01Z')
    expect(store.shellCounts.value).toEqual({ agents: 5, tasks: 9, keepers: 7, total_runtimes: 12, configured_keepers: 13 })
    expect(store.shellAuthSummary.value).not.toBeNull()
    expect(store.shellConfigResolution.value?.config_root.path).toBe('older-shell')
    expect(store.executionWorkspaceAuthority.peek()).toBe(owner)
    if (kind === 'bootstrap') expect(store.tasks.peek().find(task => task.id === 'task-bootstrap-observation')?.title).toBe('execution-body-2')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('keeps accepted namespace HTTP status when an older independent execution HTTP completes later', async () => {
    const older = delayed(), namespace = delayed()
    const fetch = vi.fn((path: string, _init?: RequestInit) =>
      path === '/api/v1/dashboard/project-snapshot' ? namespace.promise : older.promise)
    vi.stubGlobal('fetch', fetch)
    const { store } = await surface()
    stop?.(); stop = undefined
    store.hydrateExecutionSnapshot(execution())
    const owner = store.executionWorkspaceAuthority.peek()
    const pending = store.refreshExecution({ immediate: true })
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1))
    namespaceActions = await import('./namespace-truth-actions')
    const namespaceRead = namespaceActions.refreshNamespaceTruth({ force: true })
    await flush()
    expect(fetch.mock.calls.map(([path]) => path)).toEqual([
      '/api/v1/dashboard/execution',
      '/api/v1/dashboard/project-snapshot',
    ])
    const current = { ...shell('accepted-namespace'), status: {
      project: 'fixture-project', workspace_root: '/workspace', generated_at: '2026-11-10T00:00:01Z',
    }, counts: { agents: 5, tasks: 9, keepers: 7 }, configured_keepers: 13 }
    namespace.resolve(json({
      projection_diagnostics: { read_completeness: 'complete', read_error: null },
      root: current,
    }))
    await namespaceRead
    expect(store.serverStatus.value?.generated_at).toBe('2026-11-10T00:00:01Z')
    older.resolve(json({ ...execution(2), status: {
      project: 'older-execution', workspace_root: '/workspace', generated_at: '2026-11-10T00:00:00Z',
    } }))
    await pending
    expect(store.serverStatus.value?.project).toBe('fixture-project')
    expect(store.serverStatus.value?.generated_at).toBe('2026-11-10T00:00:01Z')
    expect(store.tasks.peek().find(task => task.id === 'task-bootstrap-observation')?.title).toBe('execution-body-2')
    expect(store.executionWorkspaceAuthority.peek()).toBe(owner)
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('treats an accepted bootstrap namespace root as a completion before an older Shell read returns', async () => {
    const older = delayed(), bootstrap = delayed()
    const fetch = vi.fn((path: string, _init?: RequestInit) => path === '/api/v1/dashboard/bootstrap' ? bootstrap.promise : older.promise)
    vi.stubGlobal('fetch', fetch)
    const { store } = await surface()
    stop?.(); stop = undefined
    store.hydrateExecutionSnapshot(execution())
    const owner = store.executionWorkspaceAuthority.peek()
    const shellRead = store.refreshShell({ force: true })
    await flush()
    const bootstrapRead = store.refreshDashboard({ force: true })
    await flush()
    const current = { ...shell('bootstrap-namespace'), status: {
      project: 'fixture-project', workspace_root: '/workspace', generated_at: '2026-11-10T00:00:01Z',
    }, counts: { agents: 5, tasks: 9, keepers: 7 }, configured_keepers: 13 }
    const old = { ...shell('older-shell'), status: {
      project: 'fixture-project', workspace_root: '/workspace', generated_at: '2026-11-10T00:00:00Z',
    } }
    bootstrap.resolve(json({ shell: old, execution: execution(2), namespace_truth: { projection_diagnostics: completeRead, root: current } }))
    await bootstrapRead
    expect(store.executionWorkspaceAuthority.peek()).toBe(owner)
    expect(store.tasks.peek().find(task => task.id === 'task-bootstrap-observation')?.title).toBe('execution-body-2')
    expect(fetch.mock.calls[0]?.[1]?.signal?.aborted).toBe(false)
    expect(store.shellCounts.value?.tasks).toBe(9)
    older.resolve(json(old))
    expect(await shellRead).toBe(true)
    expect(store.serverStatus.value?.generated_at).toBe('2026-11-10T00:00:01Z')
    expect(store.shellCounts.value?.tasks).toBe(9)
    expect(store.shellCounts.value?.configured_keepers).toBe(13)
    expect(store.shellConfigResolution.value?.config_root.path).toBe('older-shell')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it.each(['shell', 'bootstrap'] as const)('retains a read owed by canonical completion when the older %s says initializing', async kind => {
    const held = delayed()
    const current = { ...shell('completed'), counts: { agents: 5, tasks: 9, keepers: 7 }, configured_keepers: 13 }
    const fetch = vi.fn().mockImplementationOnce(() => held.promise).mockResolvedValue(json(current))
    vi.stubGlobal('fetch', fetch)
    const { store } = await surface()
    const pending = kind === 'shell' ? store.refreshShell({ force: true }) : store.refreshDashboard({ force: true })
    const { hydrateServerPushEvent } = await import('./sse-store')
    hydrateServerPushEvent({ type: 'project_snapshot', payload: { projection_diagnostics: completeRead, root: current } })
    const old = { status: { project: 'initializing' }, counts: { agents: 0, tasks: 0, keepers: 0 }, auth: null }
    held.resolve(json(kind === 'shell' ? old : { shell: old, execution: { projection_diagnostics: completeRead }, namespace_truth: { status: 'initializing' } }))
    await pending
    await flush()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(store.shellCounts.value?.tasks).toBe(9)
    expect(store.shellConfigResolution.value?.config_root.path).toBe('completed')
    expect(store.shellAuthSummary.value).not.toBeNull()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it.each([
    ['token', 'initializing'], ['token', 'failure'],
    ['connection', 'initializing'], ['connection', 'failure'],
    ['workspace', 'initializing'], ['workspace', 'failure'],
  ] as const)('keeps the current refusal debt when an older bootstrap crosses %s then returns %s', async (boundary, outcome) => {
    const held = delayed()
    const fetch = vi.fn().mockImplementationOnce(() => held.promise).mockImplementation(() =>
      Promise.resolve(new Response('{"error":"forbidden"}', { status: 403 })))
    vi.stubGlobal('fetch', fetch)
    const { store } = await surface()
    stop?.(); stop = undefined
    const core = await import('./api/core')
    core.setStoredToken('original')
    const older = store.refreshDashboard({ force: true })
    if (boundary === 'token') core.setStoredToken('replacement')
    else if (boundary === 'connection') store.resetExecutionSnapshotGeneration()
    else store.hydrateExecutionSnapshot({
      projection_diagnostics: completeRead,
      execution_publication_epoch: 'replacement-process', execution_publication_generation: 1,
      observer_instance_id: 'instance-B', status: { project: 'B', workspace_root: '/B' },
    })
    const { hydrateServerPushEvent } = await import('./sse-store')
    hydrateServerPushEvent({ type: 'project_snapshot', payload: { projection_diagnostics: completeRead, root: {
      status: { project: 'B' }, counts: { tasks: 9 }, configured_keepers: 13,
    } } })
    expect(await store.refreshShell({ force: true })).toBe(false)
    expect(fetch).toHaveBeenCalledTimes(2)
    if (outcome === 'failure') held.reject(new Error('retired bootstrap failed'))
    else held.resolve(json({ shell: { status: { project: 'initializing' }, auth: null },
      execution: { status: { project: 'retired-A' } }, namespace_truth: { root: { status: { project: 'retired-A' } } } }))
    await older
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(store.serverStatus.value?.project).toBe('B')
    expect(store.shellCounts.value?.tasks).toBe(9)
    expect(effects.toast).toHaveBeenCalledTimes(1)
  })

  it.each(['success', 'failure'] as const)('aborts the last mounted read and suppresses its late %s effects', async outcome => {
    const held = delayed()
    const fetch = vi.fn((_path: string, _init?: RequestInit) => held.promise)
    vi.stubGlobal('fetch', fetch)
    const { store, observation } = await surface()
    observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    await flush()
    const signal = (fetch.mock.calls[0]?.[1] as RequestInit).signal!
    stop?.(); stop = undefined
    expect(signal.aborted).toBe(true)
    if (outcome === 'success') held.resolve(json({ ...shell('late'), auth: {
      enabled: true, require_token: true, token_present: true, token_valid: false, auth_error_code: 'invalid_token',
    } }))
    else held.reject(new Error('late error'))
    await flush()
    expect(store.serverStatus.value).toBeNull()
    expect(store.shellAuthSummary.value).toBeNull()
    expect(effects.recoverCredential).not.toHaveBeenCalled()
    expect(effects.toast).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it('lets a manual waiter finish a shared read after the mounted caller leaves', async () => {
    const held = delayed()
    const fetch = vi.fn((_path: string, _init?: RequestInit) => held.promise)
    vi.stubGlobal('fetch', fetch)
    const { store, observation } = await surface()
    observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    await flush()
    const manual = store.refreshShell()
    stop?.(); stop = undefined
    expect((fetch.mock.calls[0]?.[1] as RequestInit).signal?.aborted).toBe(false)
    held.resolve(json(shell('manual')))
    expect(await manual).toBe(true)
    expect(store.serverStatus.value?.project).toBe('manual')
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it('retains store-owned failure recovery for a manual waiter after the original caller leaves', async () => {
    const held = delayed()
    const fetch = vi.fn().mockImplementationOnce(() => held.promise).mockResolvedValue(json(shell('recovered')))
    vi.stubGlobal('fetch', fetch)
    const { store, observation } = await surface()
    observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    await flush()
    const manual = store.refreshShell()
    stop?.(); stop = undefined
    held.reject(new Error('temporary failure'))
    expect(await manual).toBe(false)
    await vi.advanceTimersByTimeAsync(3_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(store.serverStatus.value?.project).toBe('recovered')
  })

  it('keeps caller cancellation connected after response headers while JSON body is pending', async () => {
    let body!: ReadableStreamDefaultController<Uint8Array>
    const response = new Response(new ReadableStream<Uint8Array>({ start(controller) {
      body = controller
      body.enqueue(new TextEncoder().encode('{"status":'))
    } }), { headers: { 'content-type': 'application/json' } })
    let bodyStarted!: () => void
    const readingBody = new Promise<void>(resolve => { bodyStarted = resolve })
    const text = response.text.bind(response)
    vi.spyOn(response, 'text').mockImplementation(() => { bodyStarted(); return text() })
    const fetch = vi.fn((_path: string, init: RequestInit) => {
      init.signal?.addEventListener('abort', () => body.error(new DOMException('cancelled', 'AbortError')), { once: true })
      return Promise.resolve(response)
    })
    vi.stubGlobal('fetch', fetch)
    const { store } = await surface()
    const api = await import('./api/dashboard-hot')
    const read = api.fetchDashboardShell
    let actualRead!: ReturnType<typeof read>
    vi.spyOn(api, 'fetchDashboardShell').mockImplementation(options => { actualRead = read(options); return actualRead })
    const caller = new AbortController()
    const pending = store.refreshShell({ signal: caller.signal })
    await readingBody
    caller.abort()
    expect(fetch.mock.calls[0]?.[1].signal?.aborted).toBe(true)
    expect(await pending).toBe(false)
    await expect(actualRead).rejects.toMatchObject({ name: 'AbortError' })
    expect(store.shellAuthSummary.value).toBeNull()
    expect(effects.toast).not.toHaveBeenCalled()
    expect(vi.getTimerCount()).toBe(0)
  })

  it('retires a read when its original caller aborts synchronously as fetch starts', async () => {
    const held = delayed()
    const caller = new AbortController()
    const fetch = vi.fn((_path: string, _init?: RequestInit) => { caller.abort(); return held.promise })
    vi.stubGlobal('fetch', fetch)
    const { store } = await surface()
    expect(await store.refreshShell({ signal: caller.signal })).toBe(false)
    expect(fetch.mock.calls[0]?.[1]?.signal?.aborted).toBe(true)
    held.resolve(json(shell('cancelled')))
    await flush()
    expect(store.serverStatus.value).toBeNull()
    expect(effects.toast).not.toHaveBeenCalled()
  })

  it('reads the accepted replacement workspace once and fences the cancelled original response', async () => {
    const held = delayed()
    const fetch = vi.fn().mockImplementationOnce(() => held.promise).mockResolvedValue(json(shell('B')))
    vi.stubGlobal('fetch', fetch)
    const { store, observation } = await surface()
    observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    await flush()
    store.hydrateExecutionSnapshot({
      projection_diagnostics: completeRead,
      execution_publication_epoch: 'process', execution_publication_generation: 1,
      observer_instance_id: 'instance-B', status: { project: 'B', workspace_root: '/B' },
    })
    await flush()
    expect((fetch.mock.calls[0]?.[1] as RequestInit).signal?.aborted).toBe(true)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(store.shellConfigResolution.value?.config_root.path).toBe('B')
    held.resolve(json(shell('retired-A')))
    await flush()
    expect(store.serverStatus.value?.project).toBe('B')
    expect(store.shellConfigResolution.value?.config_root.path).toBe('B')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it.each(['token', 'actor', 'workspace'] as const)('cancels an original %s authority and refuses its late response', async boundary => {
    const held = delayed()
    const fetch = vi.fn((_path: string, _init?: RequestInit) => held.promise)
    vi.stubGlobal('fetch', fetch)
    const { store } = await surface()
    // Isolate the original read's authority handling from the mounted replacement read.
    stop?.(); stop = undefined
    const core = await import('./api/core')
    const actor = await import('./lib/dashboard-session-actor')
    const pending = store.refreshShell({ force: true })
    await flush()
    if (boundary === 'token') core.setStoredToken('replacement')
    else if (boundary === 'actor') actor.setCanonicalDashboardActor('replacement')
    else store.hydrateExecutionSnapshot({
      projection_diagnostics: completeRead,
      execution_publication_epoch: 'process', execution_publication_generation: 1,
      observer_instance_id: 'instance-B', status: { project: 'B', workspace_root: '/B' },
    })
    expect((fetch.mock.calls[0]?.[1] as RequestInit).signal?.aborted).toBe(true)
    expect(await pending).toBe(false)
    held.resolve(json(shell('retired')))
    await flush()
    expect(store.serverStatus.value?.project).not.toBe('retired')
    expect(store.shellAuthSummary.value).toBeNull()
    expect(effects.toast).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it('keeps actual failed-read debt under the store retry owner and settles it on success', async () => {
    const fetch = vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValue(json(shell('recovered')))
    vi.stubGlobal('fetch', fetch)
    const { store, observation } = await surface()
    observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    await flush()
    expect(vi.getTimerCount()).toBe(1)
    await vi.advanceTimersByTimeAsync(2_999)
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(store.serverStatus.value?.project).toBe('recovered')
    expect(vi.getTimerCount()).toBe(0)
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it.each([401, 403])('does not turn HTTP %s refusal into a recovery timer', async status => {
    const fetch = vi.fn().mockResolvedValue(new Response('{"error":"forbidden"}', {
      status, headers: { 'content-type': 'application/json' },
    }))
    vi.stubGlobal('fetch', fetch)
    const { observation } = await surface()
    observation.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    await flush()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it.each(['headers', 'body'] as const)('suppresses credential recovery when cancelled before late 401 %s', async stage => {
    const core = await import('./api/core')
    const api = await import('./api/dashboard-hot')
    core.setStoredToken('original-token')
    const rejected = vi.fn()
    core.setRejectedCredentialListener(rejected)
    const caller = new AbortController()
    const held = delayed()
    let body!: ReadableStreamDefaultController<Uint8Array>
    const response = stage === 'headers'
      ? new Response('{"auth_error_code":"invalid_token"}', { status: 401 })
      : new Response(new ReadableStream<Uint8Array>({ start(controller) {
        body = controller; body.enqueue(new TextEncoder().encode('{"auth_error_code":'))
      } }), { status: 401 })
    let bodyStarted!: () => void
    const readingBody = new Promise<void>(resolve => { bodyStarted = resolve })
    let reportRead!: Promise<string>
    const clone = response.clone.bind(response)
    vi.spyOn(response, 'clone').mockImplementation(() => {
      const copy = clone()
      const text = copy.text.bind(copy)
      vi.spyOn(copy, 'text').mockImplementation(() => { reportRead = text(); bodyStarted(); return reportRead })
      return copy
    })
    const fetch = vi.fn().mockImplementation(() => stage === 'headers' ? held.promise : Promise.resolve(response))
    vi.stubGlobal('fetch', fetch)
    const pending = api.fetchDashboardShell({ signal: caller.signal }).catch(error => error)
    if (stage === 'body') await readingBody
    caller.abort()
    if (stage === 'headers') held.resolve(response)
    else { body.enqueue(new TextEncoder().encode('"invalid_token"}')); body.close(); await reportRead }
    await pending
    expect(rejected).not.toHaveBeenCalled()
    expect(core.getStoredToken()).toBe('original-token')
    core.setRejectedCredentialListener(null)
  })
})
