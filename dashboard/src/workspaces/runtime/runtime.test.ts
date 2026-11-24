import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  activeViewStreamKey,
  authSession,
  releaseAllViewStreams,
  resetAuthStateForTests,
  resetObserverStateForTests,
  resetTimeWindowForTests,
  resourceCache,
  setTimeWindow,
} from '../../core'
import { RuntimeWorkspace, type WorkspaceInspectPayload } from './index'
import { classifyQuotaScope, partitionQuotaScopes, type ProviderUsageScope } from './types'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

function pendingSseResponse(): Response {
  const stream = new ReadableStream<Uint8Array>({
    start() {
      // keep open until aborted
    },
  })
  return new Response(stream, {
    status: 200,
    headers: { 'Content-Type': 'text/event-stream' },
  })
}

async function flushUi(ms = 25): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms))
}

describe('workspaces/runtime', () => {
  let container: HTMLDivElement
  let originalFetch: typeof globalThis.fetch

  beforeEach(() => {
    originalFetch = globalThis.fetch
    // Provide lightweight 2D canvas + Path2D stubs for real uPlot rendering in happy-dom
    if (typeof (globalThis as Record<string, unknown>).Path2D === 'undefined') {
      class StubPath2D {
        moveTo() {}
        lineTo() {}
        rect() {}
        arc() {}
        closePath() {}
        addPath() {}
      }
      ;(globalThis as Record<string, unknown>).Path2D = StubPath2D
    }
    vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockImplementation(() => ({
      save: () => {},
      restore: () => {},
      scale: () => {},
      clearRect: () => {},
      fillRect: () => {},
      strokeRect: () => {},
      beginPath: () => {},
      closePath: () => {},
      moveTo: () => {},
      lineTo: () => {},
      rect: () => {},
      arc: () => {},
      clip: () => {},
      fill: () => {},
      stroke: () => {},
      setLineDash: () => {},
      translate: () => {},
      rotate: () => {},
      fillText: () => {},
      strokeText: () => {},
      measureText: (t: string) => ({ width: t.length * 7 }),
      createLinearGradient: () => ({ addColorStop: () => {} }),
      drawImage: () => {},
      font: '11px monospace',
      fillStyle: '',
      strokeStyle: '',
      lineWidth: 1,
      lineJoin: 'round',
      lineCap: 'butt',
      textAlign: 'left',
      textBaseline: 'alphabetic',
      globalAlpha: 1,
    }) as unknown as CanvasRenderingContext2D)
    // Provide deterministic clientHeight/clientWidth for VirtualList scroll viewports in happy-dom
    // (@tanstack/virtual-core reads element.clientWidth / element.clientHeight in observeElementRect)
    vi.spyOn(HTMLElement.prototype, 'clientHeight', 'get').mockImplementation(function (this: HTMLElement) {
      if (this.classList.contains('vlist') || this.classList.contains('dtable-scroll')) return 400
      return 0
    })
    vi.spyOn(HTMLElement.prototype, 'clientWidth', 'get').mockImplementation(function (this: HTMLElement) {
      if (this.classList.contains('vlist') || this.classList.contains('dtable-scroll')) return 1100
      return 0
    })
    resetAuthStateForTests()
    resetObserverStateForTests()
    resetTimeWindowForTests('24h')
    releaseAllViewStreams()
    resourceCache.clearAll()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    releaseAllViewStreams()
    resourceCache.clearAll()
    globalThis.fetch = originalFetch
    vi.restoreAllMocks()
  })

  it('partitions 3-tier Quotas with $0 Sub / $0 Exhausted / ? Unreported honesty and handles HTTP 200 unavailable + {1,7,14} clamp', async () => {
    const scopes: ProviderUsageScope[] = [
      {
        scope: 'openai:credit',
        providers: [{ id: 'openai', display_name: 'OpenAI API' }],
        state: 'reported',
        windows: [{
          limit_id: 'credits',
          window: { kind: 'seven_day' },
          utilization: { unit: 'credit_balance', currency: 'USD', total: 50, remaining: 0 },
          resets_at: null,
          observed_at: 1_700_000_000,
          source: 'api',
          role: 'gates_model_calls',
        }],
      },
      {
        scope: 'claude:pro',
        providers: [{ id: 'anthropic', display_name: 'Claude Max' }],
        state: 'reported',
        windows: [{
          limit_id: '5h',
          window: { kind: 'five_hour' },
          utilization: { unit: 'fraction', value: 0.42 },
          resets_at: Math.floor(Date.now() / 1000) + 3600,
          observed_at: 1_700_000_000,
          source: 'cli',
          role: 'gates_model_calls',
        }],
      },
      {
        scope: 'local:ollama',
        providers: [{ id: 'ollama', display_name: 'Ollama Local' }],
        state: 'not_reported_since_start',
        windows: [],
      },
    ]

    expect(classifyQuotaScope(scopes[0]!).badge).toBe('$0 Exhausted')
    expect(classifyQuotaScope(scopes[1]!).badge).toBe('$0 Sub')
    expect(classifyQuotaScope(scopes[2]!).badge).toBe('? Unreported')

    const part = partitionQuotaScopes(scopes)
    expect(part.tier1ExhaustedOrCredits).toHaveLength(1)
    expect(part.tier2ActiveSubscriptions).toHaveLength(1)
    expect(part.tier3Unreported).toHaveLength(1)

    // Switch timeWindow to '30d' -> MUST clamp provider-usage-history days to 14 (NEVER 30!)
    setTimeWindow('30d')

    const seenUrls: string[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      seenUrls.push(url)
      if (url.startsWith('/api/v1/runtime/resolved')) {
        return jsonResponse({
          config_path: 'runtime.toml',
          default_route: 'default',
          default_runtime: null,
          runtimes: [],
          lanes: [],
          assignments: [],
          provider_usage_windows: scopes,
        })
      }
      if (url.startsWith('/api/v1/dashboard/provider-usage-history')) {
        return jsonResponse({
          state: 'unavailable',
          reason: 'usage history sqlite store disabled',
        })
      }
      if (url.startsWith('/api/v1/setup/inventory')) {
        return jsonResponse({ integrations: [] })
      }
      return jsonResponse({})
    }) as typeof fetch

    const onNavigate = vi.fn()
    const onInspect = vi.fn()

    render(
      html`<${RuntimeWorkspace} subroute="quotas" onNavigate=${onNavigate} onInspect=${onInspect} />`,
      container,
    )
    await flushUi(40)

    // Verify days=14 clamp on 30d window
    expect(seenUrls).toContain('/api/v1/dashboard/provider-usage-history?days=14')
    expect(seenUrls.some((u) => u.includes('days=30'))).toBe(false)

    // Verify HTTP 200 { state: "unavailable", reason } explicit card
    const unavail = container.querySelector('[data-testid="provider-usage-unavailable"]')
    expect(unavail).not.toBeNull()
    expect(unavail!.textContent).toContain('usage history sqlite store disabled')

    // Verify 3-tier partition rendering: Tier 1 & Tier 2 visible, Tier 3 collapsed by default
    expect(container.querySelector('[data-testid="quota-tier-1"]')!.textContent).toContain('$0 Exhausted')
    expect(container.querySelector('[data-testid="quota-tier-2"]')!.textContent).toContain('$0 Sub')
    const tier3 = container.querySelector('[data-testid="quota-tier-3"]')!
    expect(tier3.textContent).not.toContain('Ollama Local')

    // Click expand on Tier 3 -> reveals unreported account
    const toggleBtn = tier3.querySelector('button[aria-expanded]') as HTMLButtonElement
    toggleBtn.click()
    await flushUi(10)
    expect(tier3.textContent).toContain('Ollama Local')
    expect(tier3.textContent).toContain('? Unreported')

    // Verify 1-click Open Config Key remediation navigates to /settings?key=providers.<id>
    const openKeyBtn = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('Open Config Key'),
    )
    expect(openKeyBtn).toBeDefined()
    openKeyBtn!.click()
    expect(onNavigate).toHaveBeenCalledWith('/settings?key=providers.openai')
  })

  it('enforces 2+1 SSE discipline on 4-panel Efficiency: live SSE ONLY on 24h, snapshot on 7d/30d, never 2nd SSE', async () => {
    const sseCalls: string[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/stream')) {
        sseCalls.push(url)
        return pendingSseResponse()
      }
      if (url.startsWith('/api/v1/dashboard/cache-stats')) {
        return jsonResponse({
          entries: 12, fresh: 10, stale: 2, expired: 0, ready_fresh: 10, ready_stale: 2,
          computing: 0, max_entries: 128, hits_total: 420, misses_total: 80, hit_ratio: 0.84,
          timeout_circuit_open: 0, timeout_circuit_tracked: 4, entries_truncated_to: 50, entry_details: [],
        })
      }
      if (url.startsWith('/api/v1/models/metrics')) {
        return jsonResponse({
          window_minutes: 1440,
          bucket_minutes: 60,
          total_entries: 24,
          total_error_entries: 1,
          models: [{
            model_id: 'runtime_lane_abcdef012345',
            entry_count: 24,
            avg_tok_per_sec: 48,
            p50_latency_ms: 820,
            p95_latency_ms: 1400,
            total_input_tokens: 10_000,
            total_output_tokens: 2_500,
            total_cache_read_tokens: 7_500,
            cached_input: { input_tokens: 10_000, cache_read_tokens: 7_500, sample_count: 24 },
            total_cache_creation_tokens: 500,
            success_count: 23,
            error_count: 1,
            total_cost_usd: 1.25,
            total_tool_calls: 15,
            buckets: [
              { ts_start: 1_700_000_000, entry_count: 12, success_count: 12, error_count: 0, p50_latency_ms: 800, p95_latency_ms: 1200, error_rate: 0, total_cost_usd: 0.6, cache_hit_ratio: 0.75 },
              { ts_start: 1_700_003_600, entry_count: 12, success_count: 11, error_count: 1, p50_latency_ms: 840, p95_latency_ms: 1400, error_rate: 0.08, total_cost_usd: 0.65, cache_hit_ratio: 0.78 },
            ],
          }],
        })
      }
      if (url.startsWith('/api/v1/dashboard/provider-usage-history')) {
        return jsonResponse({ days: 1, generated_at: 1_700_003_600, sampling: 'latest_provider_report_per_utc_day', unreadable_reports: 0, reported_no_windows: [], points: [] })
      }
      if (url.startsWith('/api/v1/tool-metrics/series')) {
        return jsonResponse({
          generated_at: 1_700_003_600,
          window: { since: 1_699_920_000, until: 1_700_003_600, bucket: 'hour', bucket_seconds: 3600 },
          tool: null,
          total: { call_count: 10, failure_count: 1, failure_classes: { dependency_unavailable: 0, policy_rejection: 0, runtime_failure: 1, workflow_rejection: 0, operator_cancelled: 0 }, failure_unclassified_count: 0, deferred_count: 0, total_ms: 1200, p50_ms: 90, p95_ms: 210, max_ms: 300 },
          buckets: [],
        })
      }
      if (url.startsWith('/api/v1/dashboard/exact-lane-runs')) {
        return jsonResponse({ generated_at: '2026-11-24T00:00:00Z', count: 1, total: 1, has_more: false, runs: [{ run_id: 'r1', run_kind: 'exact_output', lane: 'verifier_exact', subject_id: null, actor: 'sangsu', started_at: 1_700_000_000, status: 'succeeded' }] })
      }
      if (url.startsWith('/api/v1/dashboard/keeper-costs')) {
        return jsonResponse({
          window_minutes: 1440,
          keepers: [{
            keeper_name: 'code-reviewer-sister',
            total_cost_usd: null,
            cost_reported_samples: 0,
            cost_unreported_samples: 5,
            total_input_tokens: 5000,
            total_output_tokens: 1200,
            total_tokens: 6200,
            tokens_reported_samples: 5,
            p50_latency_ms: 400,
            p95_latency_ms: 900,
            sample_count: 5,
          }],
        })
      }
      if (url.startsWith('/api/v1/keeper-efficiency')) {
        return jsonResponse({
          month: '2026-11',
          generated_at: 1_700_003_600,
          days_covered: 10,
          keepers: [],
          fleet: { turns_total: 5, calls_per_turn: 2, tool_s_per_turn: 1.2, output_tokens_per_turn: 240, input_tokens_per_turn: 1000, cost_usd_per_turn: 0 },
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${RuntimeWorkspace} subroute="efficiency" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(40)

    // On 24h: strictly 1 view SSE ('runtime-efficiency') on models/metrics/stream
    expect(activeViewStreamKey.value).toBe('runtime-efficiency')
    expect(sseCalls).toEqual(['/api/v1/models/metrics/stream?window=1440&bucket_min=60'])
    expect(container.textContent).toContain('code-reviewer-sister')
    expect(container.textContent).toContain('미보고')

    // Switch to 7d -> MUST release view-scoped SSE stream and stay snapshot-only
    setTimeWindow('7d')
    await flushUi(40)
    expect(activeViewStreamKey.value).toBeNull()
    expect(sseCalls).toHaveLength(1)
    expect(container.querySelector('[data-testid="efficiency-stream-badge"]')!.textContent).toContain('SNAPSHOT (7d)')
  })

  it('virtualizes 240+ Runtime probes cleanly under <1,000 DOM nodes and opens Exact Output Quick-Peek on click', async () => {
    const probes = Array.from({ length: 240 }, (_, i) => ({
      runtime_id: `rt-${i}`,
      provider_id: i % 2 === 0 ? 'openai' : 'anthropic',
      provider_display_name: i % 2 === 0 ? 'OpenAI' : 'Anthropic',
      model_id: `model-${i}`,
      protocol: 'openai',
      runtime_kind: 'http',
      transport: 'http',
      status: i % 10 === 0 ? 'http_error' : 'reachable',
      reachable: i % 10 !== 0,
      http_status: i % 10 === 0 ? 429 : 200,
      latency_ms: 80 + i,
      error: i % 10 === 0 ? 'rate limited' : null,
      checked_at: '2026-11-24T00:00:00Z',
    }))

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.startsWith('/api/v1/runtime/resolved')) {
        return jsonResponse({
          config_path: 'runtime.toml',
          default_route: 'default',
          default_runtime: null,
          runtimes: [],
          lanes: [{ id: 'default', declared: true, runtime_ids: ['rt-0', 'rt-1', 'rt-2'] }],
          assignments: [{ keeper: 'sangsu', assignment_source: 'default', resolved: { kind: 'lane', id: 'default' } }],
        })
      }
      if (url.startsWith('/api/v1/dashboard/runtime-probe')) {
        return jsonResponse({
          generated_at: '2026-11-24T00:00:00Z',
          cache_ttl_sec: 60,
          cache_age_sec: 4,
          cache_hit: true,
          refresh_state: 'fresh',
          probe: {
            status: 'ok',
            probe_ok: true,
            checked_at: '2026-11-24T00:00:00Z',
            summary: { runtimes: 240, probed: 240, reachable: 216, failed: 24, skipped: 0, default_runtime_id: 'rt-0' },
            providers: probes,
            errors: [],
            observations: [],
            limitations: [],
          },
        })
      }
      if (url.startsWith('/api/v1/dashboard/exact-lane-runs/run-exact-1')) {
        return jsonResponse({
          generated_at: '2026-11-24T00:00:00Z',
          run: {
            run_id: 'run-exact-1',
            run_kind: 'exact_output',
            lane: 'librarian_exact',
            subject_id: null,
            actor: 'sangsu',
            started_at: 1_700_000_000,
            status: 'succeeded',
            selected_slot: 'slot-a',
            output: { verdict: 'ok' },
            payload_availability: { input: { state: 'available' }, output: { state: 'available' } },
          },
        })
      }
      if (url.startsWith('/api/v1/dashboard/exact-lane-runs')) {
        return jsonResponse({
          generated_at: '2026-11-24T00:00:00Z',
          count: 1,
          total: 1,
          has_more: false,
          runs: [{
            run_id: 'run-exact-1',
            run_kind: 'exact_output',
            lane: 'librarian_exact',
            subject_id: null,
            actor: 'sangsu',
            started_at: 1_700_000_000,
            status: 'succeeded',
            elapsed_s: 1.42,
          }],
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    const inspected: WorkspaceInspectPayload[] = []
    render(
      html`<${RuntimeWorkspace} subroute="lanes" onNavigate=${vi.fn()} onInspect=${(p: WorkspaceInspectPayload) => inspected.push(p)} />`,
      container,
    )
    await flushUi(50)

    // Strict < 1,000 DOM nodes even with 240 probes!
    const totalDomNodes = container.querySelectorAll('*').length
    expect(totalDomNodes).toBeLessThan(1000)
    const renderedProbeRows = container.querySelectorAll('[data-testid="failover-probes-list"] .vlist-row').length
    expect(renderedProbeRows).toBeGreaterThan(0)
    expect(renderedProbeRows).toBeLessThan(60)

    // Switch to Exact Output tab and click row -> opens onInspect Quick-Peek Drawer
    const exactTabBtn = Array.from(container.querySelectorAll('button[role="tab"]')).find((b) =>
      b.textContent?.trim() === 'Exact Output',
    ) as HTMLButtonElement
    exactTabBtn.click()
    await flushUi(40)

    const rowEl = container.querySelector('tbody tr') as HTMLTableRowElement
    expect(rowEl).not.toBeNull()
    rowEl.click()
    await flushUi(40)

    expect(inspected.length).toBeGreaterThanOrEqual(1)
    expect(inspected[inspected.length - 1]!.kind).toBe('exact_lane_run')
    expect(inspected[inspected.length - 1]!.title).toContain('librarian_exact')
  })

  it('launches Fusion with closed topology union and acquires single runtime-tools SSE on Tools tab', async () => {
    const postCalls: { url: string; body: unknown }[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.includes('/tool-metrics/series/stream')) return pendingSseResponse()
      if (url.startsWith('/api/v1/dashboard/fusion-runs')) {
        return jsonResponse({ generated_at: '2026-11-24T00:00:00Z', count: 0, runs: [] })
      }
      if (url.startsWith('/api/v1/keepers/') && url.endsWith('/fusion') && init?.method === 'POST') {
        postCalls.push({ url, body: JSON.parse(String(init.body)) })
        return jsonResponse({ ok: true, run_id: 'fus-1' })
      }
      if (url.startsWith('/api/v1/tool-metrics/series')) {
        return jsonResponse({
          generated_at: 1_700_003_600,
          window: { since: 1_699_920_000, until: 1_700_003_600, bucket: 'hour', bucket_seconds: 3600 },
          tool: null,
          total: { call_count: 5, failure_count: 0, failure_classes: { dependency_unavailable: 0, policy_rejection: 0, runtime_failure: 0, workflow_rejection: 0, operator_cancelled: 0 }, failure_unclassified_count: 0, deferred_count: 0, total_ms: 500, p50_ms: 80, p95_ms: 120, max_ms: 150 },
          buckets: [],
        })
      }
      if (url.startsWith('/api/v1/dashboard/tools')) {
        return jsonResponse({ tools: [{ name: 'masc_board_post', description: 'Post to board', calls: 0, failure_rate: 0, p95_ms: 42 }] })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${RuntimeWorkspace} subroute="lanes" entityTab="fusion" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(30)

    const openModalBtn = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('+ Fusion 실행'),
    ) as HTMLButtonElement
    openModalBtn.click()
    await flushUi(15)

    const form = container.querySelector('[data-testid="fusion-launch-form"]') as HTMLFormElement
    const keeperInput = form.querySelector('input[type="text"]') as HTMLInputElement
    const topoSelect = form.querySelector('select') as HTMLSelectElement
    const promptArea = form.querySelector('textarea') as HTMLTextAreaElement

    keeperInput.value = 'sangsu'
    keeperInput.dispatchEvent(new Event('input', { bubbles: true }))
    topoSelect.value = 'judge_of_judges'
    topoSelect.dispatchEvent(new Event('change', { bubbles: true }))
    promptArea.value = 'Evaluate architecture trade-offs'
    promptArea.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi(10)

    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await flushUi(30)

    expect(postCalls).toHaveLength(1)
    expect(postCalls[0]!.url).toBe('/api/v1/keepers/sangsu/fusion')
    expect(postCalls[0]!.body).toMatchObject({
      prompt: 'Evaluate architecture trade-offs',
      topology: 'judge_of_judges',
      web_tools: false,
    })

    // Render Tools tab -> acquires 'runtime-tools' view SSE on 24h
    render(
      html`<${RuntimeWorkspace} subroute="tools" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(35)
    expect(activeViewStreamKey.value).toBe('runtime-tools')
    expect(container.textContent).toContain('masc_board_post')
  })

  it('handles Browser Lane HTTP 503 unattached state gracefully on Addons tab', async () => {
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.startsWith('/api/v1/lane-addons')) {
        return jsonResponse({ configuration: null, instances: [], rows: [], coverage: [] })
      }
      if (url.startsWith('/api/v1/dashboard/browser-lane/clients')) {
        return jsonResponse({ ok: false, error: 'browser lane addon is not attached' }, 503)
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${RuntimeWorkspace} subroute="addons" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(40)

    const card503 = container.querySelector('[data-testid="browser-lane-503"]')
    expect(card503).not.toBeNull()
    expect(card503!.textContent).toContain('HTTP 503')
    expect(card503!.textContent).toContain('browser lane addon is not attached')
  })

  it('loads multi_account provider_accounts verbatim from /api/v1/auth/provider-accounts', async () => {
    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'user-1',
      email: 'ops@example.com',
      displayName: 'Ops',
      role: 'worker',
      csrfToken: 'csrf-tok-1',
      authMethods: { google: true, github: false, dev_token: false },
      workspaceId: 'default',
    }

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.startsWith('/api/v1/auth/provider-accounts')) {
        return jsonResponse({
          provider_accounts: [{
            provider_account_id: 'pa-codex-01',
            integration_id: 'openai_codex',
            kind: 'login',
          }],
          runtimes: [],
        })
      }
      if (url.startsWith('/api/v1/runtime/resolved')) {
        return jsonResponse({ config_path: null, default_route: null, default_runtime: null, runtimes: [], lanes: [], assignments: [], provider_usage_windows: [] })
      }
      if (url.startsWith('/api/v1/dashboard/provider-usage-history')) {
        return jsonResponse({ state: 'unavailable', reason: 'no history yet' })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${RuntimeWorkspace} subroute="quotas" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(40)

    expect(container.textContent).toContain('pa-codex-01')
    expect(container.textContent).toContain('openai_codex')
  })
})
