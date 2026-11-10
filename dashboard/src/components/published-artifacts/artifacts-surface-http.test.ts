import { html } from 'htm/preact'
import { act, cleanup, render } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from '../../api/core'
import { acceptedExecutionWorkspace } from '../../execution-workspace-authority'
import { TRANSPORT_RETRY_BASE_MS, TRANSPORT_RETRY_MAX_MS } from '../../config/constants'
import { publishDashboardObservationChange, publishDashboardObservationRecovery } from '../../lib/observation-refresh'
import { confirmRuntimeTestWorkspace } from '../../lib/runtime-workspace.test-fixture'
import { navigate, route } from '../../router'
import { ArtifactDraftSessionProvider } from './artifact-draft-session'
import { ArtifactsSurface } from './artifacts-surface'

const firstId = `artifact-${'a'.repeat(32)}`
const secondId = `artifact-${'b'.repeat(32)}`
const artifact = (id: string) => ({ id, revision: 1, title: id, summary: '', format: 'markdown',
  author: 'fixture', created_at: '2026-11-10T00:00:00Z', task_id: null, goal_id: null,
  body: { _blob: { sha256: 'a'.repeat(64) } }, url: `/dashboard/#/workspace?section=artifacts&artifact=${id}` })
const documentPayload = (id: string, content: string) => ({ artifact: artifact(id), content, revisions: [artifact(id)] })
type Request = { url: URL; init: RequestInit }
let bodies: Request[]
let lists: number
let readBody: (request: Request) => Promise<Response>
const jsonDocument = (request: Request, content: string) => Response.json(
  documentPayload(request.url.pathname.split('/').at(-1)!, content),
  { headers: { 'x-masc-workspace-read': 'matched-v1' } },
)
const settle = () => act(async () => {
  await vi.advanceTimersByTimeAsync(0)
  await vi.dynamicImportSettled()
})
const advance = (milliseconds: number) => act(async () => { await vi.advanceTimersByTimeAsync(milliseconds) })
const mount = () => render(html`<${ArtifactDraftSessionProvider}><${ArtifactsSurface} /><//>`)

beforeEach(() => {
  vi.useFakeTimers()
  setStoredToken('artifact-http-owner-a', { source: 'manual' })
  confirmRuntimeTestWorkspace()
  route.value = { tab: 'workspace', params: { section: 'artifacts', artifact: firstId }, postId: null }
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.spyOn(console, 'warn').mockImplementation(() => {})
  bodies = []
  lists = 0
  readBody = async request => jsonDocument(request, 'body-current')
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = new URL(String(input), window.location.origin)
    if (url.pathname === '/health') return Response.json({ paths: {
      effective_base_path: '/fixture/runtime-consumer', effective_masc_root: '/fixture/runtime-consumer/.masc',
    } })
    if (url.pathname === '/api/v1/published-artifacts') {
      lists++
      return Response.json({ artifacts: [artifact(firstId), artifact(secondId)], diagnostics: [] })
    }
    if (url.pathname === '/api/v1/published-artifact-checks') return Response.json({ checks: [], diagnostics: [] })
    if (url.pathname.startsWith('/api/v1/published-artifacts/')) {
      const request = { url, init }
      bodies.push(request)
      return readBody(request)
    }
    throw new Error(`Unexpected HTTP read: ${url.pathname}`)
  }))
})

afterEach(() => {
  cleanup()
  acceptedExecutionWorkspace.value = null
  clearStoredToken()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('selected published document HTTP ownership', () => {
  it.each(['503', 'network'] as const)('recovers a %s body failure without a later event and then stays quiet', async failure => {
    let unavailable = true
    readBody = async request => {
      if (!unavailable) return jsonDocument(request, 'body-recovered')
      if (failure === 'network') throw new TypeError('connection lost')
      return Response.json({ error: 'temporarily unavailable' }, { status: 503 })
    }
    const view = mount()
    await settle()
    expect(lists).toBe(1)
    expect(bodies).toHaveLength(2)
    expect(view.queryByText(/body-recovered/)).toBeNull()
    unavailable = false
    await advance(TRANSPORT_RETRY_BASE_MS)
    await settle()
    expect(bodies).toHaveLength(4)
    expect(view.getByText(/body-recovered/)).toBeTruthy()
    await advance(TRANSPORT_RETRY_MAX_MS * 4)
    expect(bodies).toHaveLength(4)
    expect(lists).toBe(1)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('retains retry debt when unbound viewing succeeds but workspace-bound HTTP fails', async () => {
    let unavailable = true
    readBody = async request => unavailable && request.url.searchParams.has('expected_base_path')
      ? Response.json({ error: 'bound read unavailable' }, { status: 503 })
      : jsonDocument(request, unavailable ? 'body-unbound' : 'body-attested')
    const view = mount()
    await settle()
    expect(view.getByText(/body-unbound/)).toBeTruthy()
    unavailable = false
    await advance(TRANSPORT_RETRY_BASE_MS)
    await settle()
    expect(view.getByText(/body-attested/)).toBeTruthy()
    expect(bodies.filter(r => r.url.searchParams.has('expected_base_path'))).toHaveLength(2)
    await advance(TRANSPORT_RETRY_MAX_MS * 4)
    expect(bodies).toHaveLength(4)
  })

  it('keeps a successful unattested document quiet without repeatedly fetching it', async () => {
    readBody = async request => Response.json(documentPayload(request.url.pathname.split('/').at(-1)!, 'body-unattested'))
    const view = mount()
    await settle()
    expect(view.getByText(/body-unattested/)).toBeTruthy()
    expect(bodies).toHaveLength(2)
    await advance(TRANSPORT_RETRY_MAX_MS * 4)
    expect(bodies).toHaveLength(2)
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each([401, 403])('keeps HTTP%s terminal through public fallback until the actual credential changes', async status => {
    readBody = async request => request.init.credentials === 'omit'
      ? jsonDocument(request, 'body-public')
      : new Headers(request.init.headers).get('Authorization') === 'Bearer artifact-http-owner-a'
        ? Response.json({ error: 'access refused' }, { status })
        : jsonDocument(request, 'body-owner-b')
    const view = mount()
    await settle()
    expect(bodies).toHaveLength(3)
    expect(view.getByText(/body-public/)).toBeTruthy()
    publishDashboardObservationChange({ topic: 'published_artifacts' })
    publishDashboardObservationRecovery()
    window.dispatchEvent(new Event('focus'))
    await advance(TRANSPORT_RETRY_MAX_MS * 4)
    expect(bodies).toHaveLength(3)
    await act(async () => { setStoredToken('artifact-http-owner-b', { source: 'manual' }) })
    await settle()
    expect(view.getByText(/body-owner-b/)).toBeTruthy()
    expect(bodies).toHaveLength(5)
    expect(bodies.slice(3).every(request => new Headers(request.init.headers).get('Authorization') === 'Bearer artifact-http-owner-b')).toBe(true)
    await advance(TRANSPORT_RETRY_MAX_MS * 4)
    expect(bodies).toHaveLength(5)
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each(['selection', 'credential', 'workspace', 'unmount'] as const)('aborts actual %s reads and rejects noncooperative late response bodies', async replacement => {
    const pending: { finish: (body: string) => void; request: Request }[] = []
    readBody = async request => {
      const response = jsonDocument(request, 'unused')
      response.text = () => new Promise(resolve => pending.push({ finish: resolve, request }))
      return response
    }
    const view = mount()
    await settle()
    expect(pending).toHaveLength(2)
    const old = [...pending]
    readBody = async request => jsonDocument(request, 'body-replacement')
    await act(async () => {
      if (replacement === 'selection') {
        navigate('workspace', { section: 'artifacts', artifact: secondId })
        navigate('workspace', { section: 'artifacts', artifact: firstId })
      } else if (replacement === 'credential') setStoredToken('artifact-http-owner-b', { source: 'manual' })
      else if (replacement === 'workspace') confirmRuntimeTestWorkspace()
      else view.unmount()
    })
    await settle()
    expect(old.every(({ request }) => request.init.signal?.aborted === true)).toBe(true)
    if (replacement !== 'unmount') expect(view.getByText(/body-replacement/)).toBeTruthy()
    const before = bodies.length
    await act(async () => {
      for (const request of old) request.finish(JSON.stringify(documentPayload(firstId, 'body-obsolete')))
    })
    await settle()
    expect(view.queryByText(/body-obsolete/)).toBeNull()
    if (replacement !== 'unmount') expect(view.getByText(/body-replacement/)).toBeTruthy()
    await advance(TRANSPORT_RETRY_MAX_MS * 4)
    expect(bodies).toHaveLength(before)
    expect(vi.getTimerCount()).toBe(0)
  })
})
