import { html } from 'htm/preact'
import { act, cleanup, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from '../../api/core'
import { acceptedExecutionWorkspace } from '../../execution-workspace-authority'
import { publishDashboardObservationChange, publishDashboardObservationRecovery } from '../../lib/observation-refresh'
import { keepers } from '../../store'
import { IdePresenceStrip } from './ide-presence-strip'
import { IdeActivityPanel } from './ide-activity-panel'
import { IdePersistencePanel } from './ide-persistence-panel'
import { globalPresenceSnapshot, LOADING_SNAPSHOT, resetGlobalPresenceSnapshot } from './keeper-presence-store'
import { clearTraces } from './keeper-trace-store'

const keeperName = 'same-keeper'
const settle = () => act(async () => {
  await vi.advanceTimersByTimeAsync(0)
  await vi.dynamicImportSettled()
})
function workspace(label: string) {
  acceptedExecutionWorkspace.value = { epoch: `ide-${label}`, workspaceRoot: `/workspace-${label}`,
    connectionGeneration: 1, observerInstanceId: `ide-instance-${label}` }
}
function answer(path: string): Response {
  switch (new URL(path, 'http://fixture').pathname) {
    case '/api/v1/ide/presence': return Response.json({ ok: true, data: { runtime_id: 'A-evidence',
      entries: [{ keeper_id: 'A-keeper', workspace_label: 'A-workspace', role: 'keeper', status: 'active', last_seen_ms: 1 }] } })
    case '/api/v1/agents': return Response.json({ ok: true, data: { agents: [{ name: 'fallback-keeper',
      status: 'active', current_task: null, model: null }] } })
    case '/api/v1/status': return Response.json({ ok: true, data: { project: 'fallback-runtime' } })
    case '/api/v1/activity/events': return Response.json({ events: [{ seq: 1, ts_ms: Date.now(),
      ts_iso: '2026-11-10T00:00:00Z', workspace_id: 'A-workspace', kind: 'task.noted',
      actor: { kind: 'agent', id: 'A-actor' }, subject: { kind: 'task', id: 'A-task' },
      payload: { summary: 'A-evidence' }, tags: [] }], total_matching_events: 1731 })
    case '/api/v1/ide/events': return Response.json({ ok: true, data: { events: [] } })
    case '/api/v1/keepers/same-keeper/state-diagram': return Response.json({ keeper: keeperName,
      current_phase: 'A-evidence', mermaid: 'graph TD' })
    default: throw new Error(`Unexpected read: ${path}`)
  }
}
function Presence() { return html`<${IdePresenceStrip} />` }
function Activity() { return html`<${IdeActivityPanel} codebase="fixture-repo" />` }
function Persistence() { return html`<${IdePersistencePanel} keeperName=${keeperName} />` }
const surfaces = [
  { Component: Presence, name: 'Presence', topic: 'ide_presence', target: '/api/v1/ide/presence' },
  { Component: Activity, name: 'Activity', topic: 'activity', target: '/api/v1/activity/events' },
  { Component: Persistence, name: 'Persistence', topic: 'keeper_composite', target: '/api/v1/keepers/same-keeper/state-diagram' },
] as const
const pathname = (path: string) => new URL(path, 'http://fixture').pathname

beforeEach(() => {
  vi.useFakeTimers()
  localStorage.clear()
  setStoredToken('ide-observation-credential', { source: 'manual' })
  workspace('A')
  keepers.value = []
  resetGlobalPresenceSnapshot()
  clearTraces()
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.spyOn(console, 'warn').mockImplementation(() => {})
})
afterEach(() => {
  cleanup()
  acceptedExecutionWorkspace.value = null
  clearStoredToken()
  resetGlobalPresenceSnapshot()
  clearTraces()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe.each(surfaces)('$name original read cause', ({ Component, topic, target }) => {
  it.each([401, 403])('does not retry original HTTP %i after source, focus or recovery', async status => {
    const fetch = vi.fn(async (path: string) => pathname(path) === target
      ? Response.json({ error: 'access refused' }, { status }) : answer(path))
    vi.stubGlobal('fetch', fetch)
    render(html`<${Component} />`)
    await settle()
    const reads = () => fetch.mock.calls.filter(([path]) => pathname(path) === target).length
    expect(reads()).toBe(1)
    publishDashboardObservationChange({ topic, keeperName })
    window.dispatchEvent(new Event('focus'))
    publishDashboardObservationRecovery()
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(reads()).toBe(1)
    setStoredToken('actual-replacement-credential', { source: 'manual' })
    await settle()
    expect(reads()).toBe(2)
  })
})

describe.each(surfaces)('$name actual owner reset', ({ Component, topic, target }) => {
  it('withdraws same-scope A evidence immediately while B is pending and refused', async () => {
    let scope = 'A'
    let complete!: (response: Response) => void
    const fetch = vi.fn((path: string) => scope === 'B' && pathname(path) === target
      ? new Promise<Response>(resolve => { complete = resolve }) : Promise.resolve(answer(path)))
    vi.stubGlobal('fetch', fetch)
    render(html`<${Component} />`)
    await settle()
    expect(screen.queryByText('A-evidence')).not.toBeNull()
    scope = 'B'
    await act(async () => { workspace('B') })
    expect(screen.queryByText('A-evidence')).toBeNull()
    if (topic === 'ide_presence') expect(globalPresenceSnapshot.value).toEqual(LOADING_SNAPSHOT)
    if (topic === 'activity') expect(document.body.textContent).not.toContain('1731')
    await settle()
    await act(async () => { complete(Response.json({ error: 'access refused' }, { status: 403 })) })
    await settle()
    expect(screen.queryByText('A-evidence')).toBeNull()
  })
})

it('reads only the authoritative presence route and leaves a real 404 unavailable', async () => {
  const fetch = vi.fn(async (path: string) => pathname(path) === '/api/v1/ide/presence'
    ? Response.json({ error: 'route missing' }, { status: 404 }) : answer(path))
  vi.stubGlobal('fetch', fetch)
  render(html`<${Presence} />`)
  await settle()
  expect(globalPresenceSnapshot.value.kind).toBe('disconnected')
  expect(fetch.mock.calls.map(([path]) => pathname(path))).toEqual(['/api/v1/ide/presence'])
})

it('does not let a transient graph failure hide the bridge HTTP refusal', async () => {
  const fetch = vi.fn(async (path: string) => Response.json({ error: 'failed' }, {
    status: pathname(path) === '/api/v1/ide/events' ? 403 : 500,
  }))
  vi.stubGlobal('fetch', fetch)
  render(html`<${Activity} />`)
  await settle()
  publishDashboardObservationChange({ topic: 'activity' })
  window.dispatchEvent(new Event('focus'))
  publishDashboardObservationRecovery()
  await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
  expect(fetch.mock.calls.map(([path]) => pathname(path))).toEqual(['/api/v1/activity/events', '/api/v1/ide/events'])
})

it.each(['workspace', 'credential'] as const)('does not expose cached presence to another consumer after an unmounted %s change', async changed => {
  const fetch = vi.fn(async (path: string) => pathname(path) === '/api/v1/ide/presence'
    ? answer(path) : Response.json({ error: 'access refused' }, { status: 403 }))
  vi.stubGlobal('fetch', fetch)
  const header = render(html`<${Presence} />`)
  await settle()
  expect(globalPresenceSnapshot.value.kind).toBe('live')
  header.unmount()
  if (changed === 'workspace') workspace('B')
  else setStoredToken('new-owner-credential', { source: 'manual' })
  render(html`<${IdePersistencePanel} keeperName="A-keeper" />`)
  await settle()
  expect(globalPresenceSnapshot.value).toEqual(LOADING_SNAPSHOT)
  expect(screen.queryByLabelText('Keeper status: ACTIVE')).toBeNull()
  expect(fetch.mock.calls.filter(([path]) => pathname(path) === '/api/v1/ide/presence')).toHaveLength(1)
})
