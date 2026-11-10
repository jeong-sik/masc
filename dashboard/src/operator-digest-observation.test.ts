import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const flush = async () => { for (let i = 0; i < 48; i++) await Promise.resolve() }
const json = (value: unknown, status = 200) => Response.json(value, { status })
const authority = (instance = 'digest-A') => Object.freeze({ epoch: 'process', workspaceRoot: `/${instance}`,
  connectionGeneration: 1, observerInstanceId: instance })
const query = (actor: string | null = 'dashboard') => ({ actor, target_type: 'workspace',
  effective_target_type: 'workspace', target_id: null, include_workers: null, default_namespace_request: actor === null })
const body = (trace = 'initial', actor: string | null = 'dashboard', instance = 'digest-A') => ({
  observer_instance_id: instance, query: query(actor), target_type: 'workspace', trace_id: trace,
  projection_diagnostics: { read_completeness: 'complete', read_error: null },
  health: 'ok', attention_items: [], recommended_actions: [],
})
const publication = (trace = 'canonical', generation = 1, sequence = 1,
  state: 'initializing' | 'ready' | 'error' = 'ready') => ({ ...body(trace, null),
  digest_publication_generation: generation, digest_publication_sequence: sequence, digest_observation_state: state })
const held = () => {
  let resolve!: (response: Response) => void
  const promise = new Promise<Response>(yes => { resolve = yes })
  return { promise, resolve }
}
let stop: (() => void) | undefined
beforeEach(() => { vi.resetModules(); vi.useFakeTimers(); sessionStorage.clear(); localStorage.clear() })
afterEach(async () => {
  stop?.(); stop = undefined
  await flush()
  vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals()
})
async function surface(admit = true) {
  const workspace = await import('./execution-workspace-authority')
  if (admit) workspace.acceptedExecutionWorkspace.value = authority()
  const actions = await import('./operator-digest-observation')
  const signals = await import('./operator-signals')
  return { ...workspace, ...actions, ...signals }
}

describe('Operator Digest actor and workspace observation', () => {
  it.each([
    {}, { read_completeness: 'unknown', read_error: null },
    { read_completeness: 'complete', read_error: 'contradictory error' },
  ])('retains read failure instead of accepting invalid private completeness %o', async diagnostics => {
    const fetch = vi.fn().mockResolvedValue(json({ ...body(), projection_diagnostics: diagnostics }))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorDigestObservation()
    await flush()
    expect(s.operatorWorkspaceDigest.value).toBeNull()
    expect(s.operatorDigestError.value).toBeTruthy()
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it('retains private partial rows and retries the actual failed read after quiet repair', async () => {
    const partial = { ...body('private partial'), projection_diagnostics: {
      read_completeness: 'partial', read_error: 'original approval queue read failed' } }
    const fetch = vi.fn().mockResolvedValueOnce(json(partial)).mockResolvedValue(json(body('repaired')))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorDigestObservation()
    await flush()
    expect(s.operatorWorkspaceDigest.value?.trace_id).toBe('private partial')
    expect(s.operatorDigestError.value).toBe('original approval queue read failed')
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(3_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(s.operatorWorkspaceDigest.value?.trace_id).toBe('repaired')
    expect(s.operatorDigestError.value).toBeNull()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('lets a canonical partial body own its retry and keeps its actual read error visible', async () => {
    const fetch = vi.fn().mockResolvedValue(json(body()))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorDigestObservation()
    await flush()
    s.hydrateOperatorDigest({ ...publication('partial canonical', 4, 9, 'error'),
      projection_diagnostics: { read_completeness: 'partial', read_error: 'original source failure' } })
    expect(s.operatorWorkspaceDigest.value?.trace_id).toBe('partial canonical')
    expect(s.operatorDigestError.value).toBe('original source failure')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    s.hydrateOperatorDigest(publication('complete canonical', 4, 10))
    expect(s.operatorDigestError.value).toBeNull()
    expect(s.operatorWorkspaceDigest.value?.trace_id).toBe('complete canonical')
    expect(vi.getTimerCount()).toBe(0)
  })

  it('cancels a private partial retry when its matching canonical producer completes', async () => {
    const fetch = vi.fn().mockResolvedValue(json({ ...body('partial'), projection_diagnostics: {
      read_completeness: 'partial', read_error: 'original private read failure' } }))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorDigestObservation()
    await flush()
    expect(s.operatorDigestError.value).toBe('original private read failure')
    s.hydrateOperatorDigest(publication('canonical repair'))
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(s.operatorDigestError.value).toBeNull()
    expect(vi.getTimerCount()).toBe(0)
  })

  it('waits for real scope, then requests the server workspace vocabulary once', async () => {
    const fetch = vi.fn().mockResolvedValue(json(body()))
    vi.stubGlobal('fetch', fetch)
    const s = await surface(false)
    stop = s.setupOperatorDigestObservation()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).not.toHaveBeenCalled()
    s.acceptedExecutionWorkspace.value = authority()
    await flush()
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(fetch.mock.calls[0]?.[0]).toBe('/api/v1/operator/digest?target_type=workspace')
    expect(s.operatorWorkspaceDigest.value?.trace_id).toBe('initial')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it('applies matching canonical schema/dispatcher bodies without an extra GET', async () => {
    const fetch = vi.fn().mockResolvedValue(json(body()))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorDigestObservation()
    await flush()
    const { SSEMessageSchema } = await import('./schemas/sse')
    const { hydrateServerPushEvent } = await import('./sse-store')
    const event = SSEMessageSchema.parse({ type: 'operator_digest', payload: publication('current', 5, 9) })
    expect(hydrateServerPushEvent(event)).toBe(true)
    expect(s.operatorWorkspaceDigest.value?.trace_id).toBe('current')
    expect(s.hydrateOperatorDigest(publication('older', 5, 8))).toBe(false)
    for (const patch of [{ digest_publication_generation: -1 }, { digest_publication_sequence: 0.5 },
      { digest_observation_state: 'stale' }, { query: {} }]) {
      expect(SSEMessageSchema.safeParse({ type: 'operator_digest', payload: { ...publication(), ...patch } }).success).toBe(false)
    }
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
  }, 20_000)

  it.each(['old body', 'late forbidden'] as const)('fences %s after an admitted canonical completion', async outcome => {
    const old = held()
    const fetch = vi.fn().mockResolvedValueOnce(json(body())).mockImplementationOnce(() => old.promise)
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorDigestObservation()
    await flush()
    const pending = s.refreshOperatorWorkspaceDigest({ force: true })
    s.hydrateOperatorDigest(publication('canonical', 4, 8))
    expect(fetch.mock.calls[1]?.[1]?.signal.aborted).toBe(true)
    old.resolve(outcome === 'old body' ? json(body('old response')) : json({ error: 'late denied' }, 403))
    await pending; await flush()
    expect(s.operatorWorkspaceDigest.value?.trace_id).toBe('canonical')
    expect(s.operatorDigestError.value).toBeNull()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('keeps another actor response and publishes a completed read during a source burst, with one trailing read', async () => {
    const active = held(), trailing = held()
    const fetch = vi.fn().mockResolvedValueOnce(json(body('alice initial', 'alice')))
      .mockImplementationOnce(() => active.promise).mockImplementationOnce(() => trailing.promise)
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorDigestObservation()
    await flush()
    const pending = s.refreshOperatorWorkspaceDigest({ force: true })
    for (let generation = 2; generation <= 4; generation++) s.hydrateOperatorDigest(publication('dashboard only', generation, generation))
    expect(s.operatorWorkspaceDigest.value?.trace_id).toBe('alice initial')
    expect(fetch).toHaveBeenCalledTimes(2)
    active.resolve(json(body('alice completed', 'alice')))
    await pending; await flush()
    expect(s.operatorWorkspaceDigest.value?.trace_id).toBe('alice completed')
    expect(fetch).toHaveBeenCalledTimes(3)
    trailing.resolve(json(body('alice latest', 'alice')))
    await flush()
    expect(s.operatorWorkspaceDigest.value?.trace_id).toBe('alice latest')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(3)
  })

  it.each([401, 403])('latches HTTP %s without retries and resumes only on an actual credential change', async status => {
    const fetch = vi.fn().mockResolvedValueOnce(json({ error: 'denied' }, status)).mockResolvedValue(json(body('new credential')))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorDigestObservation()
    await flush()
    s.hydrateOperatorDigest(publication())
    window.dispatchEvent(new Event('focus'))
    const { publishDashboardObservationRecovery } = await import('./lib/observation-refresh')
    publishDashboardObservationRecovery()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(s.operatorDigestErrorStatus.value).toBe(status)
    const { setStoredToken } = await import('./api/core')
    setStoredToken('new token')
    await flush()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(s.operatorWorkspaceDigest.value?.trace_id).toBe('new credential')
  })

  it('withdraws A rows and A I/O immediately, including when B fails', async () => {
    const old = held()
    const fetch = vi.fn().mockResolvedValueOnce(json(body('A rows'))).mockImplementationOnce(() => old.promise)
      .mockResolvedValue(json({ error: 'B failed' }, 403))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorDigestObservation()
    await flush()
    const pending = s.refreshOperatorWorkspaceDigest({ force: true })
    s.acceptedExecutionWorkspace.value = authority('digest-B')
    expect(s.operatorWorkspaceDigest.value).toBeNull()
    expect(fetch.mock.calls[1]?.[1]?.signal.aborted).toBe(true)
    await flush()
    old.resolve(json(body('late A')))
    await pending; await flush()
    expect(s.operatorWorkspaceDigest.value).toBeNull()
    expect(s.operatorDigestErrorStatus.value).toBe(403)
    expect(fetch).toHaveBeenCalledTimes(3)
  })

  it('retains canonical error beside its rows, including repeated HTTP ordering, until a newer success', async () => {
    const failed = { ...publication('retained', 3, 8, 'error'), projection_diagnostics: { stale_reason: 'original read failed' } }
    const fetch = vi.fn().mockResolvedValueOnce(json(body())).mockResolvedValue(json(failed))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorDigestObservation()
    await flush()
    s.hydrateOperatorDigest(failed)
    expect(s.operatorDigestError.value).toBe('original read failed')
    await s.refreshOperatorWorkspaceDigest({ force: true })
    expect(s.operatorWorkspaceDigest.value?.trace_id).toBe('retained')
    expect(s.operatorDigestError.value).toBe('original read failed')
    s.hydrateOperatorDigest(publication('recovered', 3, 9))
    expect(s.operatorDigestError.value).toBeNull()
    expect(s.operatorWorkspaceDigest.value?.trace_id).toBe('recovered')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(2)
  })
})
