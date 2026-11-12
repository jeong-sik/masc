import { html } from 'htm/preact'
import { act, cleanup, render } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from '../api/core'
import { acceptedExecutionWorkspace } from '../execution-workspace-authority'
import { publishDashboardObservationChange, publishDashboardObservationRecovery } from '../lib/observation-refresh'
import { resetDashboardSessionActorForTests, setCanonicalDashboardActor } from '../lib/dashboard-session-actor'
import { route } from '../router'
import { Tools } from './tools/tools-main'
import { OverviewRuntimeStats } from './overview/runtime-stats'
import { ArtifactsSurface } from './published-artifacts/artifacts-surface'
import { ArtifactDraftSessionProvider } from './published-artifacts/artifact-draft-session'
import { DashboardHealthStrip } from './dashboard-shell'

// Ancillary resources are independent of the HTTP callbacks under test.
vi.mock('./tools/tool-state', async () => {
  const { signal } = await import('@preact/signals')
  return { toolsData: signal({ tool_inventory: { tools: [] },
    keeper_waiting_inventory: { keepers: [{ keeper_name: 'same-keeper' }] } }),
  toolsLoading: signal(false), toolsError: signal(null), subscribeToolsAutoRefresh: () => () => {} }
})
vi.mock('./schedule/schedule-state', async () => {
  const { signal } = await import('@preact/signals')
  return { scheduledAutomationProjection: signal(null), subscribeScheduledAutomationRefresh: () => () => {} }
})
vi.mock('./tools/tool-series-panel', () => ({ ToolSeriesPanel: () => null }))
vi.mock('./tools/tool-full-inventory', () => ({ FullInventoryView: () => null }))
vi.mock('./tools/config-resolution-panel', () => ({ ConfigResolutionPanel: () => null }))
vi.mock('./tools/keeper-waiting-inventory-panel', () => ({ KeeperWaitingInventoryPanel: () => null }))
vi.mock('./tools/scheduled-automation-panel', () => ({ ScheduledAutomationPanel: () => null }))
vi.mock('../lib/use-model-metrics', () => ({ useModelMetrics: () => ({ state: { kind: 'loading' }, refresh: () => {} }) }))
vi.mock('../lib/runtime-catalog-resource', async () => {
  const { signal } = await import('@preact/signals')
  return { runtimeCatalogState: signal({ status: 'loaded', data: [{ provider: 'account.one',
    provider_id: 'account', protocol: 'openai-compatible-http', usage_read_configured: true, models: [] }] }),
  loadRuntimeCatalog: () => {}, reloadRuntimeCatalog: async () => {} }
})

const keeper = 'same-keeper'
const settle = () => act(async () => { await vi.advanceTimersByTimeAsync(0); await vi.dynamicImportSettled() })
function workspace(label: string) {
  acceptedExecutionWorkspace.value = { epoch: `remaining-${label}`, workspaceRoot: `/workspace-${label}`,
    connectionGeneration: 1, observerInstanceId: `remaining-instance-${label}` }
}
const refused = (status: number) => Response.json({ error: 'access refused' }, { status })
const toolsAnswer = () => Response.json({ tool_inventory: { tools: [] }, effective_keeper_surface: {
  status: 'unavailable', keeper_name: keeper, reason: 'not_measured', detail: 'A-only-receipt' } })
const activationsAnswer = () => Response.json({ schema: 'masc.keeper-skill-activations/v1', keeper,
  skill_activations: { status: 'no_session', keeper_name: keeper } })
const usageAnswer = () => Response.json({ config_path: null, default_route: null, default_runtime: null,
  runtimes: [], lanes: [], assignments: [], provider_usage_windows: [{ scope: 'account:one',
    providers: [{ id: 'account', display_name: 'Account' }], state: 'reported', windows: [{ limit_id: null,
      window: { kind: 'provider_label', label: 'A-only-usage' }, utilization: { unit: 'usd', value: 7.5, limit: 20 },
      resets_at: null, observed_at: 1100, source: 'fixture', role: 'gates_model_calls' }] }] })
const artifactAnswer = () => Response.json({ artifacts: [{ id: `artifact-${'a'.repeat(32)}`, revision: 1,
  title: 'A-only-artifact', summary: '', format: 'markdown', author: 'author', created_at: '2026-11-10T00:00:00Z',
  task_id: null, goal_id: null, body: { _blob: { sha256: 'a'.repeat(64), bytes: 1, mime: 'text/markdown', preview: '' } },
  url: '/dashboard/#/workspace?section=artifacts' }], diagnostics: [] })
function probeAnswer() {
  return Response.json({ generated_at: '2026-11-10T00:00:00Z', refreshed_at_unix: 1,
    cache_ttl_sec: 1, cache_age_sec: 0, cache_hit: false, refresh_state: 'fresh', probe: {
      source: 'runtime.toml', status: 'unavailable', probe_ok: false, checked_at: '2026-11-10T00:00:00Z',
      summary: { runtimes: 1, probed: 1, reachable: 0, failed: 1, skipped: 0, default_runtime_id: 'A-only-runtime' },
      providers: [{ runtime_id: 'A-only-runtime', provider_id: 'account', provider_display_name: 'Account',
        model_id: 'model', model_api_name: 'model', protocol: 'openai-compatible-http', runtime_kind: 'http', transport: 'http',
        auth_kind: 'none', credential_required: false, auth_present: false, status: 'network_error', reachable: false,
        http_status: null, latency_ms: null, model_count: null, content_type: null, downloaded_bytes: null,
        endpoint_url: null, probe_url: null, error: 'unreachable', checked_at: '2026-11-10T00:00:00Z' }],
      errors: [], observations: [], limitations: [],
    } })
}
beforeEach(() => {
  vi.useFakeTimers()
  resetDashboardSessionActorForTests()
  setStoredToken('remaining-credential-A', { source: 'manual' })
  workspace('A')
  route.value = { tab: 'workspace', params: { section: 'artifacts' }, postId: null }
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.spyOn(console, 'warn').mockImplementation(() => {})
})
afterEach(async () => {
  cleanup()
  acceptedExecutionWorkspace.value = null
  clearStoredToken()
  resetDashboardSessionActorForTests()
  await settle()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})
async function mountTools() {
  const view = render(html`<${Tools} />`)
  await settle()
  await act(async () => {
    const select = view.getByRole('combobox') as HTMLSelectElement
    select.value = keeper
    select.dispatchEvent(new Event('change', { bubbles: true }))
  })
  return view
}
function mountArtifacts() { return render(html`<${ArtifactDraftSessionProvider}><${ArtifactsSurface} /><//>`) }
function recover(topic: 'tools' | 'runtime_resolved' | 'published_artifacts' | 'runtime_probe') {
  publishDashboardObservationChange({ topic })
  window.dispatchEvent(new Event('focus'))
  publishDashboardObservationRecovery()
}

describe('remaining custom observation actual HTTP', () => {
  it('withdraws the selected Keeper receipt before a same-name B read settles', async () => {
    let scope = 'A'
    const pending: Array<(response: Response) => void> = []
    const fetch = vi.fn(async (path: string) => scope === 'B'
      ? new Promise<Response>(resolve => { pending.push(resolve) })
      : path.includes('/dashboard/tools') ? toolsAnswer() : activationsAnswer())
    vi.stubGlobal('fetch', fetch)
    const view = await mountTools()
    await settle()
    expect(view.container.textContent).toContain('A-only-receipt')
    scope = 'B'
    await act(async () => { workspace('B') })
    expect(view.container.textContent).not.toContain('A-only-receipt')
    await settle()
    expect(pending).toHaveLength(2)
    await act(async () => { for (const finish of pending) finish(refused(403)) })
    await settle()
    expect(view.container.textContent).not.toContain('A-only-receipt')
  })

  it.each([401, 403])('keeps a late receipt HTTP %i visible to the helper despite an earlier sibling500', async status => {
    let finish!: (response: Response) => void
    const fetch = vi.fn(async (path: string) => path.includes('/dashboard/tools') ? refused(500)
      : new Promise<Response>(resolve => { finish = resolve }))
    vi.stubGlobal('fetch', fetch)
    await mountTools()
    await settle()
    await act(async () => { finish(refused(status)) })
    await settle()
    recover('tools')
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('withdraws provider usage immediately on credential replacement while the new read is pending', async () => {
    let scope = 'A'
    let finish!: (response: Response) => void
    const fetch = vi.fn(async (path: string) => {
      expect(path).toBe('/api/v1/runtime/resolved')
      return scope === 'A' ? usageAnswer() : new Promise<Response>(resolve => { finish = resolve })
    })
    vi.stubGlobal('fetch', fetch)
    const view = render(html`<${OverviewRuntimeStats} />`)
    await settle()
    expect(view.container.textContent).toContain('A-only-usage')
    scope = 'B'
    await act(async () => { setStoredToken('remaining-credential-B', { source: 'manual' }) })
    expect(view.container.textContent).not.toContain('A-only-usage')
    await settle()
    await act(async () => { finish(refused(403)) })
    await settle()
    recover('runtime_resolved')
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('starts the replacement usage read even when the retired transport has not settled', async () => {
    const reads: Array<{ signal: AbortSignal; finish: (response: Response) => void }> = []
    const fetch = vi.fn((_path: string, init: RequestInit) => new Promise<Response>(finish => {
      reads.push({ signal: init.signal as AbortSignal, finish })
    }))
    vi.stubGlobal('fetch', fetch)
    const view = render(html`<${OverviewRuntimeStats} />`)
    await settle()
    await act(async () => { setStoredToken('remaining-credential-B', { source: 'manual' }) })
    await settle()
    expect(reads[0]!.signal.aborted).toBe(true)
    expect(fetch).toHaveBeenCalledTimes(2)
    await act(async () => { reads[0]!.finish(usageAnswer()) })
    await settle()
    expect(view.container.textContent).not.toContain('A-only-usage')
  })

  it.each([401, 403])('does not let the artifact catalog500 hide confirmation inventory HTTP %i', async status => {
    const fetch = vi.fn(async (path: string) => refused(path === '/api/v1/published-artifacts' ? 500 : status))
    vi.stubGlobal('fetch', fetch)
    mountArtifacts()
    await settle()
    recover('published_artifacts')
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('withdraws artifact catalog rows on actor replacement before the new read fails', async () => {
    let actor = 'A'
    const pending: Array<(response: Response) => void> = []
    const fetch = vi.fn(async (path: string) => actor === 'B'
      ? new Promise<Response>(resolve => { pending.push(resolve) })
      : path === '/api/v1/published-artifacts' ? artifactAnswer() : Response.json({ checks: [], diagnostics: [] }))
    vi.stubGlobal('fetch', fetch)
    const view = mountArtifacts()
    await settle()
    expect(view.container.textContent).toContain('A-only-artifact')
    actor = 'B'
    await act(async () => { setCanonicalDashboardActor('actor-B') })
    expect(view.container.textContent).not.toContain('A-only-artifact')
    await settle()
    await act(async () => { for (const finish of pending) finish(refused(403)) })
    await settle()
    expect(view.container.textContent).not.toContain('A-only-artifact')
  })

  it('withdraws the old runtime probe chip before a replacement owner read settles', async () => {
    let scope = 'A'
    const fetch = vi.fn(async () => scope === 'A' ? probeAnswer() : new Promise<Response>(() => {}))
    vi.stubGlobal('fetch', fetch)
    const view = render(html`<${DashboardHealthStrip} />`)
    await settle()
    expect(view.container.innerHTML).toContain('A-only-runtime')
    scope = 'B'
    await act(async () => { workspace('B') })
    expect(view.container.innerHTML).not.toContain('A-only-runtime')
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
  })
})
