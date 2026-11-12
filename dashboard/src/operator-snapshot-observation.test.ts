import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const flush = async () => { for (let i = 0; i < 48; i++) await Promise.resolve() }
const json = (body: unknown, status = 200) => Response.json(body, { status })
const authority = (instance = 'snapshot-A') => Object.freeze({ epoch: 'execution-process',
  workspaceRoot: `/${instance}`, connectionGeneration: 1, observerInstanceId: instance })
const query = (actor: string | null = null) => ({ actor, view: null,
  effective_actor: actor ?? 'dashboard', effective_view: actor === null ? 'summary' : 'full',
  include_messages: true, include_keepers: true, lightweight_summary: actor === null,
  default_summary_request: actor === null })
const body = (label = 'initial', actor: string | null = null, instance = 'snapshot-A') => ({
  observer_instance_id: instance, query: query(actor), root: { project: label },
  projection_diagnostics: { read_completeness: 'complete', read_error: null },
  pending_confirm_envelope: { items: [], summary: { actor_filter: actor, filter_active: actor !== null,
    visible_count: 0, total_count: 0, hidden_count: 0, hidden_actors: [], confirm_required_actions: [] } },
})
const publication = (label = 'canonical', generation = 1, sequence = 1,
  state: 'initializing' | 'invalidated' | 'ready' | 'error' = 'ready') => ({
  ...(state === 'ready' || state === 'error' ? body(label) : { query: query(), observer_instance_id: 'snapshot-A' }),
  snapshot_epoch: 'snapshot-process', snapshot_generation: generation,
  snapshot_compute_sequence: sequence, snapshot_terminal_sequence: sequence,
  snapshot_fresh_until_unix: null, snapshot_observation_state: state,
})
const held = () => {
  let resolve!: (response: Response) => void
  const promise = new Promise<Response>(yes => { resolve = yes })
  return { promise, resolve }
}
let stop: (() => void) | undefined
let stopObserver: (() => void) | undefined
beforeEach(() => { vi.resetModules(); vi.useFakeTimers(); sessionStorage.clear(); localStorage.clear() })
afterEach(async () => {
  stopObserver?.(); stopObserver = undefined
  stop?.(); stop = undefined; await flush()
  vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals()
})
async function surface(admit = true) {
  const workspace = await import('./execution-workspace-authority')
  if (admit) workspace.acceptedExecutionWorkspace.value = authority()
  const actions = await import('./operator-actions')
  const signals = await import('./operator-signals')
  const observation = await import('./operator-snapshot-observation')
  const { hydrateServerPushEvent } = await import('./sse-store')
  const { SSEMessageSchema } = await import('./schemas/sse')
  return { ...workspace, ...actions, ...signals, ...observation,
    push: (payload: unknown) => hydrateServerPushEvent(SSEMessageSchema.parse({ type: 'operator_snapshot', payload })) }
}


async function streamSurface(admit = true, streamInstance = 'snapshot-A') {
  const { setStoredToken } = await import('./api/core')
  setStoredToken('manual transport fixture')
  let source!: ReadableStreamDefaultController<Uint8Array>
  let reads = 0, streams = 0
  let next: unknown = publication('baseline', 1, 1)
  let nextResponse: Promise<Response> | null = null
  const fetch = vi.fn((path: RequestInfo | URL) => {
    if (path === '/mcp?sse_kind=observer') {
      streams++
      return Promise.resolve(new Response(new ReadableStream<Uint8Array>({ start(controller) { source = controller } }), {
        headers: { 'content-type': 'text/event-stream', 'x-masc-sse-instance-id': streamInstance,
          'x-masc-sse-replay': 'fresh', 'x-masc-sse-idle-timeout-ms': '90000' },
      }))
    }
    if (path !== '/api/v1/operator') throw new Error(`Unexpected fixture request ${String(path)}`)
    reads++
    if (nextResponse !== null) { const response = nextResponse; nextResponse = null; return response }
    return Promise.resolve(json(next))
  })
  vi.stubGlobal('fetch', fetch)
  const s = await surface(admit)
  stop = s.setupOperatorSnapshotObservation()
  await flush()
  const transport = await import('./dashboard-observer')
  const counters = await import('./dashboard-observer-state')
  stopObserver = transport.disconnectDashboardObserver
  transport.connectDashboardObserver()
  await flush()
  return { ...s, counters, reads: () => reads, streams: () => streams,
    nextBody: (body: unknown) => { next = body },
    nextResponse: (response: Promise<Response>) => { nextResponse = response },
    emit: (event: unknown) => source.enqueue(new TextEncoder().encode(`data: ${JSON.stringify(event)}\n\n`)),
    keepalive: () => source.enqueue(new TextEncoder().encode(': healthy keepalive\n\n')) }
}

describe('Operator Snapshot actual HTTP and SSE ownership', () => {
  it('does not request data before the execution workspace is accepted', async () => {
    const fetch = vi.fn().mockResolvedValue(json(body()))
    vi.stubGlobal('fetch', fetch)
    const s = await surface(false)
    await s.refreshOperatorSnapshot({ force: true })
    expect(fetch).not.toHaveBeenCalled()
    expect(s.operatorSnapshot.value).toBeNull()
  })

  it('keeps the actual actor query when a default canonical completion arrives', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(json(body('alice private', 'alice')))
      .mockResolvedValue(json(body('alice latest', 'alice')))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    await s.refreshOperatorSnapshot({ force: true })
    s.push(publication('dashboard summary'))
    expect(s.operatorSnapshot.value?.root.project).toBe('alice private')
    await flush()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(s.operatorSnapshot.value?.root.project).toBe('alice latest')
  })

  it.each(['body', '403'])('fences a late HTTP %s after a matching immutable canonical completion', async late => {
    const old = held()
    const fetch = vi.fn().mockResolvedValueOnce(json(body())).mockImplementationOnce(() => old.promise)
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    await s.refreshOperatorSnapshot({ force: true })
    const pending = s.refreshOperatorSnapshot({ force: true })
    s.push(publication('new canonical', 2, 8))
    old.resolve(late === 'body' ? json(body('old HTTP')) : json({ error: 'late refused' }, 403))
    await pending; await flush()
    expect(s.operatorSnapshot.value?.root.project).toBe('new canonical')
    expect(s.operatorError.value).toBeNull()
  })

  it('subscribes before the initial read, resumes unknown scope once, and has no healthy cadence', async () => {
    const fetch = vi.fn().mockImplementation(() => json(body()))
    vi.stubGlobal('fetch', fetch)
    const s = await surface(false)
    stop = s.setupOperatorSnapshotObservation()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).not.toHaveBeenCalled()
    s.acceptedExecutionWorkspace.value = authority()
    await flush()
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(s.operatorSnapshot.value?.root.project).toBe('initial')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('preserves a same-generation private read through a source burst and owes exactly one trailing read', async () => {
    const active = held(), trailing = held()
    const fetch = vi.fn().mockResolvedValueOnce(json(body('alice initial', 'alice')))
      .mockImplementationOnce(() => active.promise).mockImplementationOnce(() => trailing.promise)
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    await s.refreshOperatorSnapshot({ force: true })
    s.push(publication('', 1, 0, 'initializing'))
    const pending = s.refreshOperatorSnapshot({ force: true })
    for (let seq = 1; seq <= 5; seq++) s.push(publication('dashboard only', 1, seq))
    expect(fetch.mock.calls[1]?.[1]?.signal?.aborted).toBe(false)
    expect(fetch).toHaveBeenCalledTimes(2)
    active.resolve(json(body('alice observed', 'alice')))
    await pending; await flush()
    expect(s.operatorSnapshot.value?.root.project).toBe('alice observed')
    expect(fetch).toHaveBeenCalledTimes(3)
    trailing.resolve(json(body('alice latest', 'alice')))
    await flush()
    expect(s.operatorSnapshot.value?.root.project).toBe('alice latest')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(3)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('withdraws approvals immediately on hard invalidation and aborts the preceding private read', async () => {
    const old = held(), fresh = held()
    const fetch = vi.fn().mockResolvedValueOnce(json(body('old approvals', 'alice')))
      .mockImplementationOnce(() => old.promise).mockImplementationOnce(() => fresh.promise)
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    await s.refreshOperatorSnapshot({ force: true })
    s.push(publication('', 1, 0, 'initializing'))
    const pending = s.refreshOperatorSnapshot({ force: true })
    s.push(publication('', 2, 0, 'invalidated'))
    expect(s.operatorSnapshot.value).toBeNull()
    expect(fetch.mock.calls[1]?.[1]?.signal?.aborted).toBe(true)
    await pending
    expect(fetch).toHaveBeenCalledTimes(3)
    old.resolve(json(body('stale approvals', 'alice')))
    fresh.resolve(json(body('current approvals', 'alice')))
    await flush()
    expect(s.operatorSnapshot.value?.root.project).toBe('current approvals')
    expect(s.operatorError.value).toBeNull()
  })

  it('waits for canonical initial and hard-invalidation completion without status GETs', async () => {
    const fetch = vi.fn().mockResolvedValue(json(publication('', 1, 0, 'initializing')))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorSnapshotObservation()
    await flush()
    expect(s.operatorSnapshot.value).toBeNull()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    s.push(publication('ready', 1, 1))
    expect(s.operatorSnapshot.value?.root.project).toBe('ready')
    s.push(publication('', 2, 0, 'invalidated'))
    expect(s.operatorSnapshot.value).toBeNull()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    s.push(publication('after mutation', 2, 2))
    expect(s.operatorSnapshot.value?.root.project).toBe('after mutation')
    expect(vi.getTimerCount()).toBe(0)
  })

  it('shows actual canonical partial rows and no-result errors while leaving retry to the source owner', async () => {
    const fetch = vi.fn().mockResolvedValue(json(body()))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorSnapshotObservation()
    await flush()
    s.push({ ...publication('partial', 1, 4, 'error'), projection_diagnostics: {
      read_completeness: 'partial', read_error: 'original approval source failed' } })
    expect(s.operatorSnapshot.value?.root.project).toBe('partial')
    expect(s.operatorError.value).toBe('original approval source failed')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    s.push({ ...publication('', 1, 4, 'error'), snapshot_terminal_sequence: 5,
      status: 'unavailable', pending_confirm_envelope: undefined, root: undefined,
      projection_diagnostics: { stale_reason: 'original no-result failure' } })
    expect(s.operatorSnapshot.value).toBeNull()
    expect(s.operatorError.value).toBe('original no-result failure')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    s.push(publication('source repaired', 1, 6))
    expect(s.operatorSnapshot.value?.root.project).toBe('source repaired')
    expect(s.operatorError.value).toBeNull()
    expect(vi.getTimerCount()).toBe(0)
  })

  it('retains an actual malformed canonical body as failed read debt instead of silently keeping old approvals', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(json(body('old approvals')))
      .mockImplementation(() => json(publication('repaired', 1, 2)))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorSnapshotObservation()
    await flush()
    s.push({ ...publication('malformed', 1, 1), pending_confirm_envelope: undefined })
    expect(s.operatorSnapshot.value).toBeNull()
    expect(s.operatorError.value).toBe('invalid pending_confirm_envelope')
    await vi.advanceTimersByTimeAsync(3_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(s.operatorSnapshot.value?.root.project).toBe('repaired')
    expect(s.operatorError.value).toBeNull()
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each(['same epoch', 'different epoch'])('does not admit a malformed high watermark or retire its %s before body validation', async epoch => {
    const fetch = vi.fn().mockResolvedValueOnce(json(publication('baseline', 1, 1)))
      .mockImplementation(() => json(publication('normal HTTP recovered', 1, 2)))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorSnapshotObservation()
    await flush()
    s.push({ ...publication('malformed high watermark', 100, 100),
      snapshot_epoch: epoch === 'same epoch' ? 'snapshot-process' : 'unadmitted-process',
      pending_confirm_envelope: undefined })
    expect(s.operatorSnapshot.value).toBeNull()
    expect(s.operatorError.value).toBe('invalid pending_confirm_envelope')
    await vi.advanceTimersByTimeAsync(3_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(s.operatorSnapshot.value?.root.project).toBe('normal HTTP recovered')
    expect(s.operatorError.value).toBeNull()
    s.push(publication('normal SSE recovered', 1, 3))
    expect(s.operatorSnapshot.value?.root.project).toBe('normal SSE recovered')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each(['older', 'same'])('ignores a malformed %s publication before it can withdraw current approved rows', async order => {
    const fetch = vi.fn().mockImplementation(() => json(publication('current rows', 2, 3)))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorSnapshotObservation()
    await flush()
    s.push({ ...publication('unadmitted stale body', order === 'same' ? 2 : 1, 3),
      pending_confirm_envelope: undefined })
    expect(s.operatorSnapshot.value?.root.project).toBe('current rows')
    expect(s.operatorError.value).toBeNull()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each(['generation', 'compute sequence', 'terminal sequence', 'retired epoch'] as const)(
    'preserves displayed approvals and retries when HTTP has an older %s', async order => {
      const current = publication('current approvals', 2, 7)
      const stale = { ...current, root: { project: 'stale approvals' } }
      if (order === 'generation') stale.snapshot_generation = 1
      if (order === 'compute sequence') stale.snapshot_compute_sequence = 6
      if (order === 'terminal sequence') stale.snapshot_terminal_sequence = 6
      const epoch = order === 'retired epoch' ? 'replacement epoch' : current.snapshot_epoch
      const fetch = vi.fn().mockResolvedValueOnce(json(current))
        .mockResolvedValueOnce(json(stale))
        .mockResolvedValue(json({ ...publication('recovered approvals', 2, 8), snapshot_epoch: epoch }))
      vi.stubGlobal('fetch', fetch)
      const s = await surface()
      stop = s.setupOperatorSnapshotObservation()
      await flush()
      if (order === 'retired epoch') s.push({ ...current, snapshot_epoch: epoch })
      await s.refreshOperatorSnapshot({ force: true })
      expect(s.operatorSnapshot.value?.root.project).toBe('current approvals')
      expect(s.operatorError.value).toBeNull()
      expect(s.operatorErrorStatus.value).toBeNull()
      expect(vi.getTimerCount()).toBe(1)
      await vi.advanceTimersByTimeAsync(3_000)
      expect(fetch).toHaveBeenCalledTimes(3)
      expect(s.operatorSnapshot.value?.root.project).toBe('recovered approvals')
      expect(s.operatorError.value).toBeNull()
      await vi.advanceTimersByTimeAsync(300_000)
      expect(fetch).toHaveBeenCalledTimes(3)
      expect(vi.getTimerCount()).toBe(0)
    },
  )

  it('retains owed recovery when a Current HTTP body precedes an accepted hard mutation', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(json(publication('baseline', 1, 1)))
      .mockResolvedValueOnce(json(publication('older HTTP', 1, 2)))
      .mockImplementation(() => json(publication('current HTTP', 2, 3)))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorSnapshotObservation()
    await flush()
    s.push(publication('', 2, 0, 'invalidated'))
    expect(s.operatorSnapshot.value).toBeNull()
    expect(vi.getTimerCount()).toBe(0)
    await s.refreshOperatorSnapshot({ force: true })
    expect(s.operatorSnapshot.value).toBeNull()
    expect(s.operatorError.value).toContain('precedes the accepted publication')
    expect(vi.getTimerCount()).toBe(1)
    await vi.advanceTimersByTimeAsync(3_000)
    expect(fetch).toHaveBeenCalledTimes(3)
    expect(s.operatorSnapshot.value?.root.project).toBe('current HTTP')
    expect(s.operatorError.value).toBeNull()
    expect(vi.getTimerCount()).toBe(0)
  })

  it('settles a known current-instance invalid envelope from the actual admitted transport and recovers on quiet keepalive bytes', async () => {
    const s = await streamSurface()
    expect(s.reads()).toBe(2)
    s.nextBody(publication('Current recovered', 1, 2))
    s.emit({ type: 'operator_snapshot', payload: { observer_instance_id: 'snapshot-A' } })
    await flush()
    expect(s.operatorSnapshot.value).toBeNull()
    expect(s.operatorError.value).toContain('envelope is invalid')
    expect(s.counters.dashboardObserverRejectedFrameCount.peek()).toBe(1)
    await vi.advanceTimersByTimeAsync(3_000)
    expect(s.reads()).toBe(3)
    expect(s.operatorSnapshot.value?.root.project).toBe('Current recovered')
    expect(s.operatorError.value).toBeNull()
    for (let i = 0; i < 5; i++) {
      s.keepalive()
      await vi.advanceTimersByTimeAsync(60_000)
    }
    expect(s.reads()).toBe(3)
    expect(s.streams()).toBe(1)
  })

  it('does not let a read admitted before a malformed frame settle that frame\'s failed-read debt', async () => {
    const s = await streamSurface()
    const old = held()
    s.nextResponse(old.promise)
    const pending = s.refreshOperatorSnapshot({ force: true })
    s.emit({ type: 'operator_snapshot', payload: { observer_instance_id: 'snapshot-A' } })
    await flush()
    expect(s.operatorSnapshot.value).toBeNull()
    old.resolve(json(publication('read admitted before invalidation', 1, 1)))
    await pending; await flush()
    expect(s.operatorSnapshot.value).toBeNull()
    expect(s.operatorError.value).toContain('envelope is invalid')
    s.nextBody(publication('read after invalidation', 1, 2))
    await vi.advanceTimersByTimeAsync(3_000)
    expect(s.reads()).toBe(4)
    expect(s.operatorSnapshot.value?.root.project).toBe('read after invalidation')
    expect(s.operatorError.value).toBeNull()
  })

  it.each(['other payload instance', 'other admitted instance'])('does not attribute %s to the current rows or failure debt', async mode => {
    const s = await streamSurface(true, mode === 'other admitted instance' ? 'snapshot-B' : 'snapshot-A')
    const reads = s.reads()
    s.emit({ type: 'operator_snapshot', payload: {
      observer_instance_id: mode === 'other payload instance' ? 'snapshot-B' : 'snapshot-A' } })
    await flush()
    expect(s.operatorSnapshot.value?.root.project).toBe('baseline')
    expect(s.operatorError.value).toBeNull()
    expect(s.counters.dashboardObserverRejectedFrameCount.peek()).toBe(1)
    await vi.advanceTimersByTimeAsync(3_000)
    expect(s.reads()).toBe(reads)
  })

  it('keeps unknown scope GET0, then uses the same admitted stream only after its instance is accepted', async () => {
    const s = await streamSurface(false)
    s.emit({ type: 'operator_snapshot', payload: { observer_instance_id: 'snapshot-A' } })
    await flush()
    await vi.advanceTimersByTimeAsync(3_000)
    expect(s.reads()).toBe(0)
    expect(s.operatorError.value).toBeNull()
    s.acceptedExecutionWorkspace.value = authority()
    await flush()
    expect(s.reads()).toBe(1)
    s.nextBody(publication('scope accepted', 1, 2))
    s.emit({ type: 'operator_snapshot', payload: { observer_instance_id: 'snapshot-A' } })
    await flush()
    expect(s.operatorSnapshot.value).toBeNull()
    await vi.advanceTimersByTimeAsync(3_000)
    expect(s.reads()).toBe(2)
    expect(s.operatorSnapshot.value?.root.project).toBe('scope accepted')
  })

  it('does not let an old stream request identity poison replacement actor rows, including actor ABA', async () => {
    const s = await streamSurface()
    const { currentDashboardActor } = await import('./api/core')
    const { setCanonicalDashboardActor } = await import('./lib/dashboard-session-actor')
    const originalActor = currentDashboardActor()
    s.nextBody(publication('replacement actor', 1, 2))
    setCanonicalDashboardActor('replacement-snapshot-actor')
    await flush()
    const replacementReads = s.reads()
    s.emit({ type: 'operator_snapshot', payload: { observer_instance_id: 'snapshot-A' } })
    await flush()
    expect(s.operatorSnapshot.value?.root.project).toBe('replacement actor')
    expect(s.operatorError.value).toBeNull()
    await vi.advanceTimersByTimeAsync(3_000)
    expect(s.reads()).toBe(replacementReads)
    s.nextBody(publication('ABA actor', 1, 3))
    setCanonicalDashboardActor(originalActor)
    await flush()
    const abaReads = s.reads()
    s.emit({ type: 'operator_snapshot', payload: { observer_instance_id: 'snapshot-A' } })
    await flush()
    expect(s.operatorSnapshot.value?.root.project).toBe('ABA actor')
    expect(s.operatorError.value).toBeNull()
    await vi.advanceTimersByTimeAsync(3_000)
    expect(s.reads()).toBe(abaReads)
  })

  it('retains private partial failure debt and increases retry delay until actual complete success', async () => {
    const partial = { ...body('private partial', 'alice'), projection_diagnostics: {
      read_completeness: 'partial', read_error: 'original private source failed' } }
    const fetch = vi.fn().mockImplementationOnce(() => json(partial)).mockImplementationOnce(() => json(partial))
      .mockImplementation(() => json(body('repaired', 'alice')))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorSnapshotObservation()
    await flush()
    expect(s.operatorSnapshot.value?.root.project).toBe('private partial')
    expect(s.operatorError.value).toBe('original private source failed')
    await vi.advanceTimersByTimeAsync(3_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(4_999)
    expect(fetch).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetch).toHaveBeenCalledTimes(3)
    expect(s.operatorSnapshot.value?.root.project).toBe('repaired')
    expect(s.operatorError.value).toBeNull()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(3)
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each([401, 403])('latches %s across source/focus/reconnect/manual calls until actual credential replacement', async status => {
    const { setStoredToken, setRejectedCredentialListener } = await import('./api/core')
    setStoredToken('original managed Snapshot token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const rejected = vi.fn()
    setRejectedCredentialListener(rejected)
    const fetch = vi.fn().mockResolvedValueOnce(json({ error: 'original refusal' }, status))
      .mockImplementation(() => json(body('new credential')))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorSnapshotObservation()
    await flush()
    s.push(publication('must not install'))
    const { publishDashboardObservationRecovery } = await import('./lib/observation-refresh')
    publishDashboardObservationRecovery(); window.dispatchEvent(new Event('focus'))
    await s.refreshOperatorSnapshot({ force: true })
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(s.operatorSnapshot.value).toBeNull()
    expect(s.operatorErrorStatus.value).toBe(status)
    expect(vi.getTimerCount()).toBe(0)
    expect(rejected).toHaveBeenCalledTimes(status === 401 ? 1 : 0)
    setStoredToken('new snapshot credential')
    await flush()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(s.operatorSnapshot.value?.root.project).toBe('new credential')
    setRejectedCredentialListener(null)
  })

  it('withdraws A rows on B pending/failure and settles cancelled read joins without a late 403 side effect', async () => {
    const old = held(), next = held()
    const fetch = vi.fn().mockResolvedValueOnce(json(body('A rows'))).mockImplementationOnce(() => old.promise)
      .mockImplementationOnce(() => next.promise)
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorSnapshotObservation()
    await flush()
    const pending = s.refreshOperatorSnapshot({ force: true })
    const joined = s.refreshOperatorSnapshot({ force: true })
    s.acceptedExecutionWorkspace.value = authority('snapshot-B')
    expect(s.operatorSnapshot.value).toBeNull()
    await Promise.all([pending, joined])
    expect(fetch.mock.calls[1]?.[1]?.signal?.aborted).toBe(true)
    expect(fetch).toHaveBeenCalledTimes(3)
    old.resolve(json({ error: 'late A refusal' }, 403))
    next.resolve(json({ error: 'current B refusal' }, 403))
    await flush()
    expect(s.operatorSnapshot.value).toBeNull()
    expect(s.operatorErrorStatus.value).toBe(403)
    expect(s.operatorError.value).toContain('current B refusal')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(3)
  })

  it('physically aborts a quiet JSON body and settles both force callers at last unmount', async () => {
    let cancelled = false
    let body!: ReadableStreamDefaultController<Uint8Array>
    const stream = new ReadableStream<Uint8Array>({ start(controller) { body = controller } })
    const fetch = vi.fn(async (_path: RequestInfo | URL, init?: RequestInit) => {
      init?.signal?.addEventListener('abort', () => {
        cancelled = true
        body.error(new DOMException('Transport aborted', 'AbortError'))
      }, { once: true })
      return new Response(stream)
    })
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorSnapshotObservation()
    const secondLease = s.setupOperatorSnapshotObservation()
    const pending = s.refreshOperatorSnapshot({ force: true })
    const joined = s.refreshOperatorSnapshot({ force: true })
    await flush()
    stop(); stop = undefined
    expect(fetch.mock.calls[0]?.[1]?.signal?.aborted).toBe(false)
    secondLease()
    await Promise.all([pending, joined]); await flush()
    expect(fetch.mock.calls[0]?.[1]?.signal?.aborted).toBe(true)
    expect(cancelled).toBe(true)
    expect(s.operatorSnapshot.value).toBeNull()
    expect(s.operatorError.value).toBeNull()
    s.push(publication('late after last release'))
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('fences mounted-zero retained rows when credential/workspace changes before remount', async () => {
    const fetch = vi.fn().mockImplementation(() => json(body('A cached')))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    await s.refreshOperatorSnapshot({ force: true })
    expect(s.operatorSnapshot.value?.root.project).toBe('A cached')
    s.acceptedExecutionWorkspace.value = authority('snapshot-B')
    expect(s.operatorSnapshot.value).toBeNull()
  })

  it('rejects stale epochs/generations and malformed eight-field query/ordering contracts at the SSE boundary', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json(body())))
    const s = await surface()
    await s.refreshOperatorSnapshot({ force: true })
    s.push(publication('new', 3, 9))
    s.push(publication('old generation', 2, 20))
    s.push(publication('old sequence', 3, 8))
    expect(s.operatorSnapshot.value?.root.project).toBe('new')
    const { SSEMessageSchema } = await import('./schemas/sse')
    expect(SSEMessageSchema.safeParse({ type: 'operator_snapshot', payload: publication() }).success).toBe(true)
    for (const patch of [{ snapshot_generation: -1 }, { snapshot_terminal_sequence: 0.5 },
      { snapshot_observation_state: 'stale' }, { snapshot_fresh_until_unix: undefined },
      { query: { ...query(), include_keepers: undefined } }, { query: { ...query(), effective_actor: 'other' } }]) {
      expect(SSEMessageSchema.safeParse({ type: 'operator_snapshot', payload: { ...publication(), ...patch } }).success).toBe(false)
    }
    s.push({ ...publication('new epoch', 0, 1), snapshot_epoch: 'new-process' })
    s.push(publication('retired epoch', 99, 99))
    expect(s.operatorSnapshot.value?.root.project).toBe('new epoch')
  })

  it('treats private timeout without captured instance as failed read, never approval data', async () => {
    const fetch = vi.fn().mockResolvedValue(json({ ...body('unsafe'), query: query('alice'), error: 'timeout',
      message: 'original private timeout', observer_instance_id: undefined }))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorSnapshotObservation()
    await flush()
    expect(s.operatorSnapshot.value).toBeNull()
    expect(s.operatorError.value).toContain('did not attest')
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(1)
  })

  it('preserves an executed action receipt while its original force-read join retries, without replaying POST', async () => {
    const old = held()
    let reads = 0
    const fetch = vi.fn((path: RequestInfo | URL) => {
      if (path === '/api/v1/operator/action') return Promise.resolve(json({ status: 'ok', result: 'original receipt' }))
      if (String(path).startsWith('/api/v1/operator/digest')) return Promise.resolve(json({
        observer_instance_id: 'snapshot-A', query: { actor: null, target_id: null, include_workers: null,
          effective_target_type: 'workspace' }, projection_diagnostics: { read_completeness: 'complete', read_error: null } }))
      reads++
      if (reads === 1) return old.promise
      return Promise.resolve(reads === 2 ? json({ error: 'projection temporarily unavailable' }, 503) : json(body('latest')))
    })
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupOperatorSnapshotObservation()
    const result = await s.dispatchOperatorAction({ actor: 'dashboard', action_type: 'keeper_restart',
      target_type: 'keeper', target_id: 'keeper-A', payload: {} }, { refresh: 'background' })
    expect(result).toMatchObject({ status: 'ok', result: 'original receipt' })
    expect(s.operatorActionLog.value.map(entry => entry.outcome)).toEqual(['executed'])
    old.resolve(json(body('before action')))
    await flush()
    expect(reads).toBe(2)
    expect(s.operatorError.value).toContain('projection temporarily unavailable')
    await vi.advanceTimersByTimeAsync(3_000)
    expect(reads).toBe(3)
    expect(s.operatorSnapshot.value?.root.project).toBe('latest')
    expect(fetch.mock.calls.filter(([path]) => path === '/api/v1/operator/action')).toHaveLength(1)
    expect(s.operatorActionLog.value.map(entry => entry.outcome)).toEqual(['executed'])
  })
})
