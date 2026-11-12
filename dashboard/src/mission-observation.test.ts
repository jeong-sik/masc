import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const flush = async () => { for (let i = 0; i < 40; i++) await Promise.resolve() }
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { 'content-type': 'application/json' },
})
const authority = (instance = 'mission-A') => Object.freeze({ epoch: 'process', workspaceRoot: `/${instance}`,
  connectionGeneration: 1, observerInstanceId: instance })
const body = (project = 'current', instance = 'mission-A') => ({ observer_instance_id: instance,
  projection_diagnostics: { read_completeness: 'complete', read_error: null },
  summary: { workspace_health: project === 'initializing' ? 'initializing' : 'ok', project },
  agent_briefs: [{ agent_name: project }], keeper_briefs: [], attention_queue: [], internal_signals: [],
})
const publication = (project = 'current', generation = 1, sequence = 1,
  state: 'ready' | 'initializing' | 'error' = 'ready', instance = 'mission-A') => ({
  ...body(project, instance), mission_publication_generation: generation,
  mission_publication_sequence: sequence, mission_observation_state: state,
})
const held = () => {
  let resolve!: (value: Response) => void
  const promise = new Promise<Response>(yes => { resolve = yes })
  return { promise, resolve }
}

let stop: (() => void) | undefined
beforeEach(() => {
  vi.resetModules(); vi.useFakeTimers(); sessionStorage.clear(); localStorage.clear()
})
afterEach(async () => {
  stop?.(); stop = undefined
  await flush()
  vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals()
})

async function surface(admit = true) {
  const workspace = await import('./execution-workspace-authority')
  if (admit) workspace.acceptedExecutionWorkspace.value = authority()
  const actions = await import('./mission-actions')
  const signals = await import('./mission-signals')
  return { ...workspace, ...actions, ...signals }
}

describe('canonical Mission observation and its actual HTTP reader', () => {
  it.each([
    {}, { read_completeness: 'unknown', read_error: null },
    { read_completeness: 'complete', read_error: 'contradictory error' },
  ])('retains read failure instead of accepting invalid private completeness %o', async diagnostics => {
    const fetch = vi.fn().mockResolvedValue(json({ ...body(), projection_diagnostics: diagnostics }))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupMissionObservation()
    await flush()
    expect(s.missionSnapshot.value).toBeNull()
    expect(s.missionError.value).toBeTruthy()
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it('retains private partial rows and retries the actual failed read after quiet repair', async () => {
    const partial = { ...body('readable partial'), projection_diagnostics: {
      read_completeness: 'partial', read_error: 'actual Keeper metadata read failed' } }
    const fetch = vi.fn().mockResolvedValueOnce(json(partial)).mockResolvedValue(json(body('repaired')))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupMissionObservation()
    await flush()
    expect(s.missionSnapshot.value?.summary.project).toBe('readable partial')
    expect(s.missionError.value).toBe('actual Keeper metadata read failed')
    expect(s.missionInitializing.value).toBe(false)
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(3_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(s.missionSnapshot.value?.summary.project).toBe('repaired')
    expect(s.missionError.value).toBeNull()
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('lets canonical partial and complete bodies own recovery without a status GET', async () => {
    const fetch = vi.fn()
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    s.hydrateMissionSnapshot({ ...publication('partial canonical', 4, 9, 'error'),
      projection_diagnostics: { read_completeness: 'partial', read_error: 'original source error' } })
    stop = s.setupMissionObservation()
    expect(s.missionSnapshot.value?.summary.project).toBe('partial canonical')
    expect(s.missionError.value).toBe('original source error')
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).not.toHaveBeenCalled()
    s.hydrateMissionSnapshot(publication('complete canonical', 4, 10))
    expect(s.missionError.value).toBeNull()
    expect(s.missionSnapshot.value?.summary.project).toBe('complete canonical')
    expect(vi.getTimerCount()).toBe(0)
  })

  it('cancels a private partial retry when its canonical producer completes', async () => {
    const fetch = vi.fn().mockResolvedValue(json({ ...body('partial'), projection_diagnostics: {
      read_completeness: 'partial', read_error: 'original private read failure' } }))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupMissionObservation()
    await flush()
    expect(s.missionError.value).toBe('original private read failure')
    s.hydrateMissionSnapshot(publication('canonical repair'))
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(s.missionError.value).toBeNull()
    expect(vi.getTimerCount()).toBe(0)
  })

  it('waits without GET or rows until the original execution workspace is admitted', async () => {
    const fetch = vi.fn().mockResolvedValue(json(body()))
    vi.stubGlobal('fetch', fetch)
    const s = await surface(false)
    stop = s.setupMissionObservation()
    await s.refreshMissionSnapshot({ force: true })
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).not.toHaveBeenCalled()
    expect(s.missionSnapshot.value).toBeNull()
    s.acceptedExecutionWorkspace.value = authority()
    await flush()
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(s.missionSnapshot.value?.summary.project).toBe('current')
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it('accepts the real SSE schema and dispatcher body with zero status GETs', async () => {
    const fetch = vi.fn()
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    const { parseSSEMessage, SSEMessageSchema } = await import('./schemas/sse')
    const { hydrateServerPushEvent } = await import('./sse-store')
    const event = parseSSEMessage({ type: 'mission_snapshot', payload: publication('canonical', 3, 8) })
    expect(event).not.toBeNull()
    expect(hydrateServerPushEvent(event!)).toBe(true)
    stop = s.setupMissionObservation()
    expect(s.missionSnapshot.value?.summary.project).toBe('canonical')
    expect(s.hydrateMissionSnapshot(publication('older', 3, 7))).toBe(false)
    expect(s.hydrateMissionSnapshot(publication('wrong-instance', 4, 9, 'ready', 'mission-B'))).toBe(false)
    for (const patch of [{ mission_publication_generation: -1 }, { mission_publication_sequence: 0.5 },
      { mission_observation_state: 'stale' }, { observer_instance_id: '' }]) {
      expect(SSEMessageSchema.safeParse({ type: 'mission_snapshot', payload: { ...publication(), ...patch } }).success).toBe(false)
    }
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).not.toHaveBeenCalled()
    expect(s.missionSnapshot.value?.summary.project).toBe('canonical')
  }, 20_000)

  it.each(['ready', 'initializing', 'failure'] as const)('fences a late HTTP %s after canonical completion', async outcome => {
    const old = held()
    const fetch = vi.fn((_path: string, _init?: RequestInit) => old.promise)
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupMissionObservation()
    await flush()
    const pending = s.refreshMissionSnapshot({ force: true })
    expect(s.hydrateMissionSnapshot(publication('canonical', 4, 9))).toBe(true)
    expect(fetch.mock.calls[0]?.[1]?.signal?.aborted).toBe(true)
    old.resolve(outcome === 'failure' ? json({ error: 'late forbidden' }, 403)
      : json(body(outcome === 'initializing' ? 'initializing' : 'old')))
    await pending; await flush()
    expect(s.missionSnapshot.value?.summary.project).toBe('canonical')
    expect(s.missionError.value).toBeNull()
    expect(s.missionLoading.value).toBe(false)
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it('waits after an initializing HTTP body and applies producer completion without another GET', async () => {
    const fetch = vi.fn().mockResolvedValue(json(body('initializing')))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupMissionObservation()
    await flush()
    expect(s.missionInitializing.value).toBe(true)
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    s.hydrateMissionSnapshot(publication('completed'))
    expect(s.missionInitializing.value).toBe(false)
    expect(s.missionSnapshot.value?.summary.project).toBe('completed')
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it.each([401, 403])('retains HTTP %s refusal until an actual credential changes', async status => {
    const fetch = vi.fn().mockResolvedValueOnce(json({ error: 'forbidden' }, status))
      .mockResolvedValue(json(body('new credential')))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupMissionObservation()
    await flush()
    const { publishDashboardObservationRecovery } = await import('./lib/observation-refresh')
    window.dispatchEvent(new Event('focus'))
    publishDashboardObservationRecovery()
    await s.refreshMissionSnapshot({ force: true })
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(s.missionError.value).toBeTruthy()
    const { setStoredToken } = await import('./api/core')
    setStoredToken('replacement credential')
    await flush()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(s.missionSnapshot.value?.summary.project).toBe('new credential')
    expect(s.missionError.value).toBeNull()
  })

  it('withdraws A rows immediately, cancels A I/O and preserves B failure without accepting late A', async () => {
    const old = held()
    const fetch = vi.fn().mockResolvedValueOnce(json(body('A rows'))).mockImplementationOnce(() => old.promise)
      .mockResolvedValue(json({ error: 'B failed' }, 503))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupMissionObservation()
    await flush()
    expect(s.missionSnapshot.value?.summary.project).toBe('A rows')
    const pending = s.refreshMissionSnapshot({ force: true })
    await flush()
    const originalSignal = fetch.mock.calls[1]?.[1]?.signal as AbortSignal
    s.acceptedExecutionWorkspace.value = authority('mission-B')
    expect(s.missionSnapshot.value).toBeNull()
    expect(originalSignal.aborted).toBe(true)
    await flush()
    expect(s.missionError.value).toBeTruthy()
    old.resolve(json(body('late A')))
    await pending; await flush()
    expect(s.missionSnapshot.value).toBeNull()
    expect(fetch).toHaveBeenCalledTimes(3)
  })

  it('keeps canonical last-good rows and error visible, then settles on a newer success', async () => {
    vi.stubGlobal('fetch', vi.fn())
    const s = await surface()
    s.hydrateMissionSnapshot({ ...publication('retained rows', 4, 9, 'error'),
      projection_diagnostics: { stale_reason: 'original source refused' } })
    stop = s.setupMissionObservation()
    expect(s.missionSnapshot.value?.summary.project).toBe('retained rows')
    expect(s.missionError.value).toBe('original source refused')
    expect(s.hydrateMissionSnapshot(publication('old success', 4, 8))).toBe(false)
    s.hydrateMissionSnapshot(publication('new success', 4, 10))
    expect(s.missionError.value).toBeNull()
    expect(s.missionSnapshot.value?.summary.project).toBe('new success')
  })

  it('cancels actual failed-read retry debt when its canonical producer completes', async () => {
    const fetch = vi.fn().mockResolvedValue(json({ error: 'source offline' }, 503))
    vi.stubGlobal('fetch', fetch)
    const s = await surface()
    stop = s.setupMissionObservation()
    await flush()
    expect(s.missionError.value).toBeTruthy()
    s.hydrateMissionSnapshot(publication('recovered'))
    await vi.advanceTimersByTimeAsync(600_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(s.missionError.value).toBeNull()
  })
})
