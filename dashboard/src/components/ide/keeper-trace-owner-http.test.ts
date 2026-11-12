import { html } from 'htm/preact'
import { act, cleanup, render } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from '../../api/core'
import { acceptedExecutionWorkspace } from '../../execution-workspace-authority'
import { resetDashboardSessionActorForTests, setCanonicalDashboardActor } from '../../lib/dashboard-session-actor'
import { captureDashboardObservationOwner } from '../../lib/observation-read-owner'
import { route } from '../../router'
import { routeServerPushEvent } from '../../sse-store'
import { IdeConversationRail } from './ide-conversation-rail'
import { OverlayKeeperTrace } from './overlay-keeper-trace'
import { clearTraces, keeperTraceState, pushTrace } from './keeper-trace-store'

const settle = () => act(async () => { await vi.advanceTimersByTimeAsync(0); await vi.dynamicImportSettled() })
const pathname = (path: string) => new URL(path, 'http://fixture').pathname
function workspace(label: string) {
  acceptedExecutionWorkspace.value = { epoch: `trace-${label}`, workspaceRoot: `/workspace-${label}`,
    connectionGeneration: 1, observerInstanceId: `trace-instance-${label}` }
}
const boardAnswer = () => Response.json({ posts: [{ id: 'A-thread', author: 'A-keeper', title: 'A-only-thread',
  body: 'lib/A-only.ts:4', content: 'lib/A-only.ts:4', author_identity: { kind: 'keeper', id: 'A-keeper', key: 'A-keeper',
    display_name: 'A-keeper', raw: 'A-keeper' }, tags: [], votes: 0, comment_count: 0,
  created_at: new Date().toISOString(), updated_at: new Date().toISOString() }] })
const decisionsAnswer = () => Response.json({ events: [{ keeper_name: 'A-keeper', ts_unix: Date.now() / 1000,
  event_type: 'A-only-decision', outcome: 'success', context: { file_path: 'lib/A.ts', line: 4 } }],
limit: 200, generated_at: null })
function sourceAnswer(path: string) {
  return pathname(path) === '/api/v1/board' ? boardAnswer()
    : pathname(path) === '/api/v1/dashboard/keeper-decisions' ? decisionsAnswer()
      : (() => { throw new Error(`Unexpected trace source: ${path}`) })()
}
beforeEach(() => {
  vi.useFakeTimers()
  resetDashboardSessionActorForTests()
  setStoredToken('trace-credential-A', { source: 'manual' })
  workspace('A')
  clearTraces()
  route.value = { tab: 'code', params: {}, postId: null }
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.spyOn(console, 'warn').mockImplementation(() => {})
})
afterEach(async () => {
  cleanup()
  clearTraces()
  acceptedExecutionWorkspace.value = null
  clearStoredToken()
  resetDashboardSessionActorForTests()
  await settle()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('keeper trace original source owner', () => {
  it.each(['workspace', 'credential', 'actor'] as const)('withdraws retained actual Board/Decision traces after an unmounted %s change', async changed => {
    const fetch = vi.fn(async (path: string) => sourceAnswer(path))
    vi.stubGlobal('fetch', fetch)
    const producer = render(html`<${IdeConversationRail} />`)
    await settle()
    expect(keeperTraceState.value.events.some(event => event.keeperName === 'A-keeper')).toBe(true)
    producer.unmount()
    if (changed === 'workspace') workspace('B')
    else if (changed === 'credential') setStoredToken('trace-credential-B', { source: 'manual' })
    else setCanonicalDashboardActor('actor-B')
    const overlay = render(html`<${OverlayKeeperTrace} active=${true} />`)
    await settle()
    expect(keeperTraceState.value.events).toEqual([])
    expect(overlay.container.querySelector('[data-keeper="A-keeper"]')).toBeNull()
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('withdraws actual Board/Decision read rows and trace while the replacement workspace is pending', async () => {
    let scope = 'A'
    const pending: Array<{ signal: AbortSignal; finish: (response: Response) => void }> = []
    const fetch = vi.fn(async (path: string, init: RequestInit) => scope === 'A' ? sourceAnswer(path)
      : new Promise<Response>(finish => { pending.push({ signal: init.signal as AbortSignal, finish }) }))
    vi.stubGlobal('fetch', fetch)
    const view = render(html`<${IdeConversationRail} />`)
    await settle()
    expect(keeperTraceState.value.events.map(event => event.source).sort()).toEqual(['anchored-thread', 'decision-log'])
    expect(view.container.textContent).toContain('lib/A-only.ts:4')
    scope = 'B'
    await act(async () => { workspace('B') })
    expect(keeperTraceState.value.events).toEqual([])
    expect(view.container.textContent).not.toContain('lib/A-only.ts:4')
    await settle()
    expect(pending).toHaveLength(2)
    await act(async () => { for (const read of pending) read.finish(Response.json({ error: 'refused' }, { status: 403 })) })
    await settle()
    expect(keeperTraceState.value.events).toEqual([])
    routeServerPushEvent({ type: 'post_changed', post_id: 'A-thread', timestamp: 1 })
    routeServerPushEvent({ type: 'keeper_turn_complete', agent: 'A-keeper', timestamp: 1 })
    await act(async () => { window.dispatchEvent(new Event('focus')); await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(4)
  })

  it('does not admit late original Board/Decision bodies under the replacement owner', async () => {
    const pending: Array<{ path: string; signal: AbortSignal; finish: (response: Response) => void }> = []
    vi.stubGlobal('fetch', vi.fn((path: string, init: RequestInit) => new Promise<Response>(finish => {
      pending.push({ path, signal: init.signal as AbortSignal, finish })
    })))
    const view = render(html`<${IdeConversationRail} />`)
    await settle()
    await act(async () => { workspace('B') })
    await settle()
    expect(pending).toHaveLength(4)
    expect(pending.slice(0, 2).every(read => read.signal.aborted)).toBe(true)
    await act(async () => { for (const read of pending.slice(0, 2)) read.finish(sourceAnswer(read.path)) })
    await settle()
    expect(keeperTraceState.value.events).toEqual([])
    expect(view.container.textContent).not.toContain('lib/A-only.ts:4')
    view.unmount()
    expect(pending.slice(2).every(read => read.signal.aborted)).toBe(true)
  })

  it('refuses a delayed bridge input with its retired source owner', () => {
    const owner = captureDashboardObservationOwner()
    workspace('B')
    pushTrace({ id: 'old-input', tsMs: 1, keeperName: 'A-keeper', source: 'anchored-thread',
      threadId: 'A-thread', line: 4, filePath: 'lib/A.ts' }, owner)
    expect(keeperTraceState.value.events).toEqual([])
  })
})
