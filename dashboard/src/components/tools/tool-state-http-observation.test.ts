import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as core from '../../api/core'
import * as store from '../../store'
import * as tools from './tool-state'
import * as observations from '../../lib/observation-refresh'
import { recordManagedCredentialRefusal } from '../../lib/dashboard-session-actor'
import { fetchDashboardShell } from '../../api/dashboard-hot'
let stop: (() => void) | undefined
let generation = 0
let connectionGeneration = 0

const inventory = (name: string) => ({
  tool_inventory: { count: 1, tools: [{ name, description: name, doc_refs: [], prompt_hints: [] }] },
  tool_usage: { total_calls: 0, distinct_tools_called: 0, top_20: [], never_called_count: 1, registered_count: 1 },
})
const refusal = (status: number) => Response.json({ error: 'access refused' }, { status })
const settle = async () => { await vi.advanceTimersByTimeAsync(0) }
const firstName = () => tools.toolsData.peek()?.tool_inventory.tools[0]?.name ?? null
function workspace(root: string, requestGeneration = connectionGeneration) {
  expect(store.hydrateExecutionSnapshot({
    projection_diagnostics: { read_completeness: 'complete', read_error: null },
    execution_publication_epoch: 'tools-http-owner', execution_publication_generation: ++generation,
    observer_instance_id: root.slice(1),
    status: { project: 'tools', workspace_root: root }, agents: [], tasks: [], messages: [], keepers: [],
    execution_queue: [], worker_support_briefs: [], continuity_briefs: [],
  }, { requestGeneration })).toBe(true)
}

beforeEach(() => {
  vi.useFakeTimers()
  core.setStoredToken('tools-token-a', { source: 'manual' })
  vi.spyOn(console, 'warn').mockImplementation(() => {})
  workspace('/workspace-a')
})
afterEach(() => {
  stop?.(); stop = undefined
  core.setRejectedCredentialListener(null)
  core.clearStoredToken()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('Tools observation through the actual HTTP API', () => {
  it.each([401, 403])('keeps a store-owned original Shell HTTP %i refusal latched across recovery events', async status => {
    const fetch = vi.fn(async (_path: RequestInfo | URL, _init?: RequestInit) => refusal(status))
    vi.stubGlobal('fetch', fetch)
    let originalCause: unknown
    stop = observations.setupObservationRefresh(async signal => {
      try { await fetchDashboardShell({ signal }) }
      catch (cause) {
        originalCause = observations.retainObservationReadFailure(cause)
        throw originalCause
      }
    }, { topics: ['runtime_resolved'] })
    await settle()
    expect(originalCause).toBeInstanceOf(core.ApiRequestError)
    expect((originalCause as core.ApiRequestError).status).toBe(status)
    expect(fetch.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/shell')
    observations.publishDashboardObservationChange({ topic: 'runtime_resolved' })
    window.dispatchEvent(new Event('focus'))
    observations.publishDashboardObservationRecovery()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each([401, 403])('keeps HTTP %i refused for the same owner across source, focus and reconnect', async status => {
    const fetch = vi.fn(async () => refusal(status))
    vi.stubGlobal('fetch', fetch)
    stop = tools.subscribeToolsAutoRefresh()
    await settle()
    expect(tools.toolsError.peek()).toContain('access refused')
    expect(fetch).toHaveBeenCalledTimes(1)
    observations.publishDashboardObservationChange({ topic: 'tools' })
    window.dispatchEvent(new Event('focus'))
    observations.publishDashboardObservationRecovery()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('makes one fresh read when the refused credential really changes', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(refusal(403)).mockResolvedValue(Response.json(inventory('new credential')))
    vi.stubGlobal('fetch', fetch)
    stop = tools.subscribeToolsAutoRefresh()
    await settle()
    core.setStoredToken('tools-token-b', { source: 'manual' })
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(firstName()).toBe('new credential')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('keeps transient HTTP failure debt and stops its deadline after the read succeeds', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(refusal(500)).mockResolvedValueOnce(refusal(503))
      .mockResolvedValue(Response.json(inventory('recovered inventory')))
    vi.stubGlobal('fetch', fetch)
    stop = tools.subscribeToolsAutoRefresh()
    await settle()
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(1)
    await vi.advanceTimersByTimeAsync(999)
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetch).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(1_999)
    expect(fetch).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetch).toHaveBeenCalledTimes(3)
    expect(firstName()).toBe('recovered inventory')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(3)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('makes one fresh read when the refused workspace really changes', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(refusal(403)).mockResolvedValue(Response.json(inventory('B inventory')))
    vi.stubGlobal('fetch', fetch)
    stop = tools.subscribeToolsAutoRefresh()
    await settle()
    workspace('/workspace-b')
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(firstName()).toBe('B inventory')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('does not turn its own managed credential refusal into a new read owner', async () => {
    core.setStoredToken('managed-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    core.setRejectedCredentialListener(() => { recordManagedCredentialRefusal(core.currentStoredTokenRevision()) })
    const fetch = vi.fn(async () => Response.json({ auth_error: { code: 'invalid_token' } }, { status: 401 }))
    vi.stubGlobal('fetch', fetch)
    const onError = vi.fn()
    stop = observations.setupObservationRefresh(signal => core.get('/api/v1/dashboard/tools', { signal }), {
      topics: ['tools'], onError,
    })
    await settle()
    expect(onError.mock.calls[0]?.[0]).toBeInstanceOf(core.ApiRequestError)
    expect(onError.mock.calls[0]?.[0].status).toBe(401)
    observations.publishDashboardObservationRecovery()
    window.dispatchEvent(new Event('focus'))
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('withdraws A rows immediately while the first B HTTP read is pending and after it fails', async () => {
    let answerB!: (response: Response) => void
    const fetch = vi.fn().mockResolvedValueOnce(Response.json(inventory('A inventory')))
      .mockImplementationOnce(() => new Promise<Response>(resolve => { answerB = resolve }))
    vi.stubGlobal('fetch', fetch)
    stop = tools.subscribeToolsAutoRefresh()
    await settle()
    expect(firstName()).toBe('A inventory')
    workspace('/workspace-b')
    expect(firstName()).toBeNull()
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(firstName()).toBeNull()
    answerB(refusal(403))
    await settle()
    expect(firstName()).toBeNull()
    expect(tools.toolsError.peek()).toContain('access refused')
    expect(vi.getTimerCount()).toBe(0)
  })

  it('retires A HTTP before B and rejects A even if its body resolves late', async () => {
    let answerA!: (response: Response) => void
    let signalA!: AbortSignal
    const fetch = vi.fn().mockImplementationOnce((_path: string, init: RequestInit) => {
      signalA = init.signal!
      return new Promise<Response>(resolve => { answerA = resolve })
    }).mockResolvedValue(Response.json(inventory('B inventory')))
    vi.stubGlobal('fetch', fetch)
    stop = tools.subscribeToolsAutoRefresh()
    await settle()
    workspace('/workspace-b')
    expect(signalA.aborted).toBe(true)
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(firstName()).toBe('B inventory')
    answerA(Response.json(inventory('late A inventory')))
    await settle()
    expect(firstName()).toBe('B inventory')
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('owes one read without a timer while workspace identity is unavailable', async () => {
    const fetch = vi.fn(async () => Response.json(inventory('B inventory')))
    vi.stubGlobal('fetch', fetch)
    connectionGeneration += 1
    store.resetExecutionSnapshotGeneration()
    stop = tools.subscribeToolsAutoRefresh()
    await settle()
    observations.publishDashboardObservationChange({ topic: 'tools' })
    observations.publishDashboardObservationRecovery()
    window.dispatchEvent(new Event('focus'))
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).not.toHaveBeenCalled()
    expect(firstName()).toBeNull()
    expect(vi.getTimerCount()).toBe(0)
    workspace('/workspace-b')
    await settle()
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(firstName()).toBe('B inventory')
  })

  it('withdraws loaded rows while a previously confirmed workspace becomes unavailable', async () => {
    const fetch = vi.fn(async () => Response.json(inventory('A inventory')))
    vi.stubGlobal('fetch', fetch)
    stop = tools.subscribeToolsAutoRefresh()
    await settle()
    expect(firstName()).toBe('A inventory')
    connectionGeneration += 1
    store.resetExecutionSnapshotGeneration()
    expect(firstName()).toBeNull()
    observations.publishDashboardObservationChange({ topic: 'tools' })
    window.dispatchEvent(new Event('focus'))
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
  })
})
