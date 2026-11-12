import { html } from 'htm/preact'
import { act, cleanup, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from '../api/core'
import { hydrateExecutionSnapshot } from '../store'
import { publishDashboardObservationChange, publishDashboardObservationRecovery } from '../lib/observation-refresh'
import type { DashboardObservationTopic } from '../lib/observation-refresh'
import { AttributionPanel } from './attribution-panel'
import { SkillsPanel } from './skills-panel'
import { ToolQualityPanel } from './tool-quality-panel'
import { __resetFleetDataCoreForTests } from './fleet-data-core'
import { resetDashboardSessionActorForTests, setCanonicalDashboardActor } from '../lib/dashboard-session-actor'

const panels = [
  { name: 'Attribution', Component: AttributionPanel, topic: 'attribution', initialReads: 2 },
  { name: 'Skills', Component: SkillsPanel, topic: 'skills', initialReads: 2 },
  { name: 'Tool quality', Component: ToolQualityPanel, topic: 'tool_metrics', initialReads: 1 },
] as const
let generation = 0
function workspace(root: string) {
  expect(hydrateExecutionSnapshot({ projection_diagnostics: { read_completeness: 'complete', read_error: null }, execution_publication_epoch: 'custom-http-owner',
    execution_publication_generation: ++generation, observer_instance_id: root.slice(1),
    status: { project: 'custom', workspace_root: root }, agents: [], tasks: [], messages: [], keepers: [],
    execution_queue: [], worker_support_briefs: [], continuity_briefs: [],
  })).toBe(true)
}
const settle = () => act(async () => { await vi.advanceTimersByTimeAsync(0) })
const rejected = (status: number) => Response.json({ error: 'access refused' }, { status })
const quality = {
  total: 22, success: 21, failure: 1, success_rate: 95.5,
  by_tool: [{ name: 'A-only-tool', calls: 22, success_pct: 95.5, avg_ms: 1 }],
  by_keeper: [], failure_categories: [], hourly_trend: [],
}

beforeEach(() => {
  vi.useFakeTimers()
  resetDashboardSessionActorForTests()
  setStoredToken('custom-token-a', { source: 'manual' })
  workspace('/workspace-a')
  __resetFleetDataCoreForTests()
  vi.spyOn(console, 'warn').mockImplementation(() => {})
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
})
afterEach(() => {
  cleanup()
  clearStoredToken()
  __resetFleetDataCoreForTests()
  resetDashboardSessionActorForTests()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe.each(panels)('$name actual HTTP observation', ({ Component, topic, initialReads }) => {
  it.each([401, 403])('does not retry same-owner HTTP %i on source, focus or reconnect', async status => {
    const fetch = vi.fn(async () => rejected(status))
    vi.stubGlobal('fetch', fetch)
    render(html`<${Component} />`)
    await settle()
    expect(fetch).toHaveBeenCalledTimes(initialReads)
    publishDashboardObservationChange({ topic: topic as DashboardObservationTopic })
    window.dispatchEvent(new Event('focus'))
    publishDashboardObservationRecovery()
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(initialReads)
  })
})

describe.each(panels.filter(panel => panel.initialReads === 2))('$name combined read failures', ({ Component }) => {
  it('does not let an earlier HTTP 500 hide a refused sibling request', async () => {
    const fetch = vi.fn(async (path: string) => rejected(path === '/api/v1/skills'
      || path === '/api/v1/attribution/summary' ? 500 : 403))
    vi.stubGlobal('fetch', fetch)
    render(html`<${Component} />`)
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
    publishDashboardObservationRecovery()
    window.dispatchEvent(new Event('focus'))
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(2)
  })
})

describe('custom state withdrawal before a new workspace read settles', () => {
  it('withdraws a ready Skills catalog when the request actor changes and the new actor is refused', async () => {
    let actor = 'A'
    const reference = { identity: { source_id: 'workspace', package_id: 'a-only-skill', name: 'a-only-skill' }, content_revision: 'revision-a' }
    const fetch = vi.fn(async (path: string) => {
      if (actor === 'B') return rejected(403)
      return Response.json(path === '/api/v1/skills' ? {
        schema: 'masc.skill-snapshot/v1', state: 'ready', snapshot: {
          snapshot_revision: 'snapshot-a', catalog_revision: 'catalog-a', config: { kind: 'unreadable' }, sources: [],
          skills: [{ ...reference, description: 'workspace A evidence', body_bytes: 10 }],
          effective_skills: [reference.identity], shadows: [], rejections: [],
        }, surfaces: [{ reference, kind: 'unavailable', error: 'no profile' }],
      } : { schema: 'masc.async-request-observation/v1', status: 'ready',
        summary: { active: 0, runtime_owned: 0, ownership_unknown: 0, record_errors: 0 },
        record_errors: [], startup_recovery: null, requests: [] })
    })
    vi.stubGlobal('fetch', fetch)
    render(html`<${SkillsPanel} />`)
    await settle()
    expect(screen.queryByTestId('skill-row-a-only-skill')).not.toBeNull()
    actor = 'B'
    await act(async () => { setCanonicalDashboardActor('actor-b') })
    expect(screen.queryByTestId('skill-row-a-only-skill')).toBeNull()
    await settle()
    expect(fetch).toHaveBeenCalledTimes(4)
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(4)
  })

  it('withdraws Attribution A rows while B is pending and after B is refused', async () => {
    const pending: Array<(response: Response) => void> = []
    let scope = 'A'
    const fetch = vi.fn(async (path: string) => {
      if (scope === 'B') return new Promise<Response>(resolve => { pending.push(resolve) })
      return Response.json(path.includes('/summary')
        ? { gates: [{ gate: 'workspace-a-gate', passed: 1, policy_failed: 0, transition_blocked: 0, partial_pass: 0, total: 1 }] }
        : { events: [], count: 0 })
    })
    vi.stubGlobal('fetch', fetch)
    render(html`<${AttributionPanel} />`)
    await settle()
    expect(screen.queryByText('workspace-a-gate')).not.toBeNull()
    scope = 'B'
    await act(async () => { workspace('/workspace-b') })
    expect(screen.queryByText('workspace-a-gate')).toBeNull()
    await settle()
    expect(pending).toHaveLength(2)
    await act(async () => { for (const resolve of pending) resolve(rejected(403)) })
    await settle()
    expect(screen.queryByText('workspace-a-gate')).toBeNull()
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(4)
  })

  it('withdraws shared tool quality A rows while B is pending and after B is refused', async () => {
    let answerB!: (response: Response) => void
    const fetch = vi.fn().mockResolvedValueOnce(Response.json(quality))
      .mockImplementationOnce(() => new Promise<Response>(resolve => { answerB = resolve }))
    vi.stubGlobal('fetch', fetch)
    render(html`<${ToolQualityPanel} />`)
    await settle()
    expect(screen.queryByText('A-only-tool')).not.toBeNull()
    await act(async () => { workspace('/workspace-b') })
    expect(screen.queryByText('A-only-tool')).toBeNull()
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
    await act(async () => { answerB(rejected(403)) })
    await settle()
    expect(screen.queryByText('A-only-tool')).toBeNull()
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(2)
  })
})
