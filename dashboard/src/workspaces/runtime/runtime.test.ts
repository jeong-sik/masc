// @vitest-environment jsdom

import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  OBSERVER_SSE_INSTANCE_HEADER,
  activeViewStreamKey,
  authSession,
  bumpSessionEpoch,
  registerWorkspaceTargets,
  releaseAllViewStreams,
  resetAuthStateForTests,
  resetObserverStateForTests,
  resetTimeWindowForTests,
  resourceCache,
  selectWorkspace,
  setObserverSseInstanceId,
  setTimeWindow,
  startObserverStream,
} from '../../core'
import { RuntimeWorkspace, type WorkspaceInspectPayload } from './index'
import {
  formatLocalReleaseTime,
  formatReleaseSummary,
  groupRestingRuntimes,
  quotaRestCauseMeta,
  stripProviderPrefix,
} from './quota-rest-groups'
import { classifyQuotaScope, openViewSseStream, partitionQuotaScopes, type ProviderUsageScope, type RuntimeResolution } from './types'

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
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: false,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
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
    await vi.waitFor(() => {
      expect(container.querySelector('[data-testid="provider-usage-unavailable"]')).not.toBeNull()
      expect(container.querySelector('[data-testid="quota-tier-3"]')).not.toBeNull()
    })

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

  it.each([
    { subroute: 'tools', source: '/api/v1/tool-metrics/series', badge: 'tools-stream-badge', data: { buckets: [], total: { call_count: 0, failure_count: 0, p95_ms: null } } },
    { subroute: 'efficiency', source: '/api/v1/models/metrics', badge: 'efficiency-stream-badge', data: { models: [] } },
  ])('respects the account-mode snapshot contract for $subroute', async ({ subroute, source, badge, data }) => {
    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'ops-1',
      email: 'ops@example.com',
      displayName: 'Ops',
      role: 'worker',
      csrfToken: 'fixture-csrf',
      authMethods: { google: true, github: false, dev_token: false },
      workspaceId: 'default',
    }
    setObserverSseInstanceId('account-observer.1')
    const urls: string[] = []
    let snapshotStatus = 404
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      urls.push(url)
      if (url.startsWith(source + '?') && snapshotStatus === 200) return jsonResponse(data)
      return jsonResponse({ error: 'Metrics route unavailable' }, 404)
    }) as typeof fetch

    render(html`<${RuntimeWorkspace} subroute=${subroute} onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await vi.waitFor(() => {
      expect(container.querySelector(`[data-testid="${badge}"]`)?.textContent).toContain('UNAVAILABLE')
      expect(container.textContent).toContain('Metrics route unavailable')
    })

    snapshotStatus = 200
    setTimeWindow('7d')
    await vi.waitFor(() => {
      expect(container.querySelector(`[data-testid="${badge}"]`)?.textContent).toContain('SNAPSHOT (7d)')
    })
    expect(activeViewStreamKey.value).toBeNull()
    expect(urls.some((url) => url.includes('/stream'))).toBe(false)
  })

  it('enforces 2+1 SSE discipline on 4-panel Efficiency: live SSE ONLY on 24h, snapshot on 7d/30d, clamps keeper-costs?window=1440', async () => {
    const sseCalls: { url: string; instanceHeader: string | undefined }[] = []
    const keeperCostUrls: string[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.includes('/stream')) {
        const hdrs = (init?.headers ?? {}) as Record<string, string>
        sseCalls.push({ url, instanceHeader: hdrs[OBSERVER_SSE_INSTANCE_HEADER] })
        return pendingSseResponse()
      }
      if (url.startsWith('/api/v1/dashboard/keeper-costs')) {
        keeperCostUrls.push(url)
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
        return jsonResponse({ generated_at: '2026-11-24T00:00:00Z', count: 1, total: 1, has_more: false, runs: [{ run_id: 'r1', run_kind: 'task_verification', lane: 'verifier_exact', subject_id: 'task-1', actor: 'sangsu', started_at: 1_700_000_000, status: 'approved', elapsed_s: 2, selected_slot: null }] })
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
    await flushUi(30)

    // Before observer x-masc-sse-instance-id arrives: zero premature 400 stream fetches
    expect(sseCalls).toHaveLength(0)

    // Once observer SSE delivers x-masc-sse-instance-id: opens strictly 1 view SSE with header
    setObserverSseInstanceId('inst-live-rt.epoch-1')
    await vi.waitFor(() => {
      expect(activeViewStreamKey.value).toBe('runtime-efficiency')
      expect(sseCalls).toEqual([
        { url: '/api/v1/models/metrics/stream?window=1440&bucket_min=60', instanceHeader: 'inst-live-rt.epoch-1' },
      ])
    })
    expect(container.querySelector('.uplot-grid-2x2')).not.toBeNull()
    expect(container.textContent).toContain('code-reviewer-sister')
    expect(container.textContent).toContain('미보고')

    // Switch to 7d -> MUST release view-scoped SSE stream, stay snapshot-only, and NEVER request keeper-costs > 1440
    setTimeWindow('7d')
    await vi.waitFor(() => {
      expect(activeViewStreamKey.value).toBeNull()
      expect(container.querySelector('[data-testid="efficiency-stream-badge"]')?.textContent).toContain('SNAPSHOT (7d)')
    })
    expect(sseCalls).toHaveLength(1)
    expect(keeperCostUrls.every((u) => u === '/api/v1/dashboard/keeper-costs?window=1440')).toBe(true)
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
            completion_origin: 'producer',
            usage: null,
            elapsed_s: 1.42,
            selected_slot: 'slot-a',
            input: { kind: 'exact', payload: null },
            output: { verdict: 'ok' },
            skill_evidence: { state: 'no_keeper_skills' },
            payload_availability: { input: { state: 'available' }, output: { state: 'available' } },
          },
        })
      }
      if (url.startsWith('/api/v1/dashboard/exact-lane-runs')) {
        return jsonResponse({
          generated_at: '2026-11-24T00:00:00Z',
          count: 2,
          total: 2,
          has_more: false,
          runs: [{
            run_id: 'run-exact-1',
            run_kind: 'exact_output',
            lane: 'librarian_exact',
            subject_id: null,
            actor: 'sangsu',
            started_at: 1_700_000_000,
            status: 'succeeded',
            completion_origin: 'producer',
            usage: null,
            elapsed_s: 1.42,
            selected_slot: 'slot-a',
          }, {
            // The unfiltered listing also returns Verifier reviews.
            run_id: 'run-goal-1',
            run_kind: 'goal_verification',
            lane: 'verifier_exact',
            subject_id: 'goal-1',
            actor: 'sangsu',
            started_at: 1_699_999_000,
            status: 'running',
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
    const probeRows = '[data-testid="failover-probes-list"] .vlist-row'
    await vi.waitFor(() => expect(container.querySelector(probeRows)).not.toBeNull())

    // Strict < 1,000 DOM nodes even with 240 probes!
    const totalDomNodes = container.querySelectorAll('*').length
    expect(totalDomNodes).toBeLessThan(1000)
    const renderedProbeRows = container.querySelectorAll(probeRows).length
    expect(renderedProbeRows).toBeGreaterThan(0)
    expect(renderedProbeRows).toBeLessThan(60)

    // Switch to Exact Output tab and click row -> opens onInspect Quick-Peek Drawer
    const exactTabBtn = Array.from(container.querySelectorAll('button[role="tab"]')).find((b) =>
      b.textContent?.trim() === 'Exact Output',
    ) as HTMLButtonElement
    exactTabBtn.click()
    const rowEl = await vi.waitFor(() => {
      const exactRow = Array.from(container.querySelectorAll<HTMLTableRowElement>('tbody tr')).find(
        (row) => row.textContent?.includes('run-exact-1'),
      )
      expect(exactRow).toBeDefined()
      return exactRow!
    })
    expect(container.textContent).toContain('goal_verification')
    rowEl.click()
    await vi.waitFor(() => expect(inspected.length).toBeGreaterThanOrEqual(1))
    expect(inspected[inspected.length - 1]!.kind).toBe('exact_lane_run')
    expect(inspected[inspected.length - 1]!.title).toContain('librarian_exact')
  })

  it('reads the current Fusion run again on Observer events and reports a failed registry read', async () => {
    let wireStatus: 'running' | 'completed' | 'unavailable' = 'running'
    let stage = 'panel'
    let reads = 0
    let stream!: ReadableStreamDefaultController<Uint8Array>
    globalThis.fetch = vi.fn(async () => {
      reads += 1
      if (wireStatus === 'unavailable') return jsonResponse({ error: 'registry unavailable' }, 500)
      const completed = wireStatus === 'completed'
      return jsonResponse({
        generated_at: '2026-11-24T00:00:00Z',
        count: 1,
        replay: { status: 'not_replayed' },
        historical_evidence: [],
        runs: [{
          run_id: 'fusion-1', keeper: 'keeper-1', preset: 'panel', topology: 'simple',
          status: wireStatus, stage: completed ? 'completed' : stage,
          started_at: 100, finished_at: completed ? 112 : null,
        }],
      })
    }) as typeof fetch
    render(
      html`<${RuntimeWorkspace} subroute="lanes" entityTab="fusion" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await vi.waitFor(() => expect(container.textContent).toContain('패널 응답 수집'))
    stage = 'judge'
    const observer = startObserverStream({
      autoReconnect: false,
      fetchImpl: async () => new Response(new ReadableStream<Uint8Array>({
        start(controller) { stream = controller },
      }), { headers: { 'content-type': 'text/event-stream' } }),
    })

    const notify = (status: 'completed' | 'failed') => {
      stream.enqueue(new TextEncoder().encode(
        `event: fusion_run_status\ndata: ${JSON.stringify({ type: 'fusion_run_status', run_id: 'fusion-1', status })}\n\n`,
      ))
    }
    try {
      await vi.waitFor(() => expect(container.textContent).toContain('판정 중'))
      wireStatus = 'completed'
      notify('completed')
      await vi.waitFor(() => expect(container.textContent).toContain('12초'))
      expect(reads).toBe(3)
      wireStatus = 'unavailable'
      notify('failed')
      await vi.waitFor(() => expect(container.querySelector('[role="alert"]')?.textContent).toContain('Fusion 실행 이력 조회 실패'))
      expect(container.textContent).not.toContain('Fusion 실행 이력이 없습니다.')
    } finally {
      stream.close()
      await observer
    }
  })

  it('launches Fusion with closed topology union and acquires single runtime-tools SSE on Tools tab', async () => {
    const postCalls: { url: string; body: unknown }[] = []
    const toolStreamCalls: { url: string; instanceHeader: string | undefined }[] = []
    setObserverSseInstanceId('inst-tools.42')
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.includes('/tool-metrics/series/stream')) {
        const hdrs = (init?.headers ?? {}) as Record<string, string>
        toolStreamCalls.push({ url, instanceHeader: hdrs[OBSERVER_SSE_INSTANCE_HEADER] })
        return pendingSseResponse()
      }
      if (url.startsWith('/api/v1/dashboard/fusion-runs')) {
        return jsonResponse({
          generated_at: '2026-11-24T00:00:00Z',
          count: 0, runs: [], replay: { status: 'not_replayed' }, historical_evidence: [],
        })
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
    await vi.waitFor(() => {
      expect(activeViewStreamKey.value).toBe('runtime-tools')
      expect(container.textContent).toContain('masc_board_post')
    })
    expect(toolStreamCalls).toEqual([
      {
        url: '/api/v1/tool-metrics/series/stream?since_hours=24&bucket=hour&utc_offset_min=0',
        instanceHeader: 'inst-tools.42',
      },
    ])
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

  it('loads multi_account provider_accounts, sends exact {integration_id,key} & {provider_account_id,model}, and rejects synthetic "latest" credential revision', async () => {
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

    const postBodies: { url: string; body: Record<string, unknown> }[] = []

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (init?.method === 'POST') {
        postBodies.push({ url, body: JSON.parse(String(init.body)) as Record<string, unknown> })
        return jsonResponse({ ok: true })
      }
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
      if (url.startsWith('/api/v1/auth/integrations')) {
        return jsonResponse({
          integrations: [{
            integration_id: 'openai_codex',
            display_name: 'OpenAI Codex',
            connect: ['login', 'key'],
            models: ['gpt-5-codex'],
            calls: 'allowed',
          }],
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

    // Verify account sends exact 2-member { provider_account_id, model }
    const verifyBtn = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.trim() === '검증',
    ) as HTMLButtonElement
    verifyBtn.click()
    await flushUi(30)

    expect(postBodies[0]).toEqual({
      url: '/api/v1/setup/accounts/verify',
      body: { provider_account_id: 'pa-codex-01', model: 'gpt-5-codex' },
    })

    // Register API key sends exact { integration_id, key } (NOT api_key!)
    const openKeyFormBtn = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('+ API 키 등록'),
    ) as HTMLButtonElement
    openKeyFormBtn.click()
    await flushUi(15)

    const form = container.querySelector('form') as HTMLFormElement
    const textInput = form.querySelector('input[type="text"]') as HTMLInputElement
    const pwInput = form.querySelector('input[type="password"]') as HTMLInputElement
    textInput.value = 'openai_codex'
    textInput.dispatchEvent(new Event('input', { bubbles: true }))
    pwInput.value = 'sk-test-1234'
    pwInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi(10)

    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await flushUi(30)

    expect(postBodies[1]).toEqual({
      url: '/api/v1/setup/accounts/key',
      body: { integration_id: 'openai_codex', key: 'sk-test-1234' },
    })

    // Single-user credential save MUST NOT fabricate source_revision: 'latest' when config/raw lacks revision
    resetAuthStateForTests()
    resourceCache.clearAll()
    const singleUserPosts: string[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (init?.method === 'POST') {
        singleUserPosts.push(url)
        return jsonResponse({ ok: true })
      }
      if (url.startsWith('/api/v1/runtime/config/raw')) {
        return jsonResponse({})
      }
      if (url.startsWith('/api/v1/setup/inventory')) {
        return jsonResponse({ integrations: [{ id: 'openai', display_name: 'OpenAI', setup_support: 'full' }] })
      }
      if (url.startsWith('/api/v1/runtime/resolved')) {
        return jsonResponse({ config_path: null, default_route: null, default_runtime: null, runtimes: [], lanes: [], assignments: [], provider_usage_windows: [] })
      }
      if (url.startsWith('/api/v1/dashboard/provider-usage-history')) {
        return jsonResponse({ state: 'unavailable', reason: 'no history' })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(null, container)
    render(
      html`<${RuntimeWorkspace} subroute="quotas" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(40)

    const openBtn2 = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('+ API 키 등록'),
    ) as HTMLButtonElement
    openBtn2.click()
    await flushUi(15)

    const form2 = container.querySelector('form') as HTMLFormElement
    const pw2 = form2.querySelector('input[type="password"]') as HTMLInputElement
    pw2.value = 'sk-single-user'
    pw2.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi(10)
    form2.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await flushUi(30)

    expect(singleUserPosts).toEqual([])
    expect(container.textContent).toContain('source_revision')
  })

  it('submits Lane-Addon asks to POST /api/v1/lane-addons/ask-answer with exact {declaration_id,ask_id,answers} and enforces resolveWorkspaceUrl + sessionEpoch on openViewSseStream', async () => {
    const postCalls: { url: string; body: Record<string, unknown> }[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (init?.method === 'POST') {
        postCalls.push({ url, body: JSON.parse(String(init.body)) as Record<string, unknown> })
        return jsonResponse({ recorded: true, declaration_id: 'decl-1', ask_id: 'ask-9', answer_count: 1 })
      }
      if (url.startsWith('/api/v1/lane-addons/asks')) {
        return jsonResponse({
          asks: [{
            declaration_id: 'decl-1',
            title: 'Confirm browser workspace',
            ask_id: 'ask-9',
            asked_at: 1_700_000_000,
            context: null,
            questions: [{ id: 'q-space', prompt: '**Workspace** name?' }],
            resolution: { state: 'open' },
          }],
        })
      }
      if (url.startsWith('/api/v1/lane-addons')) {
        return jsonResponse({ configuration: null, instances: [], rows: [], coverage: [] })
      }
      if (url.startsWith('/api/v1/dashboard/browser-lane/clients')) {
        return jsonResponse({ ok: false, error: 'not attached' }, 503)
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${RuntimeWorkspace} subroute="addons" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    const asksPanel = await vi.waitFor(() => {
      const panel = container.querySelector('[data-testid="lane-addon-asks-panel"]')
      expect(panel?.querySelector('input[aria-labelledby]')).toBeInstanceOf(HTMLInputElement)
      return panel!
    })
    const input = asksPanel.querySelector('input[aria-labelledby]') as HTMLInputElement
    const prompt = document.getElementById(input.getAttribute('aria-labelledby')!)
    expect(prompt?.querySelector('strong')?.textContent).toBe('Workspace')
    expect(prompt?.textContent?.trim()).toBe('Workspace name?')
    input.value = 'masc-prod'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi(10)

    const submitBtn = Array.from(asksPanel.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('질문 응답 제출'),
    ) as HTMLButtonElement
    submitBtn.click()
    await flushUi(30)

    expect(postCalls).toEqual([{
      url: '/api/v1/lane-addons/ask-answer',
      body: {
        declaration_id: 'decl-1',
        ask_id: 'ask-9',
        answers: [{ question_id: 'q-space', response: { kind: 'wrote', text: 'masc-prod' } }],
      },
    }])

    // Verify openViewSseStream honors resolveWorkspaceUrl, sends x-masc-sse-instance-id, and drops frames after bumpSessionEpoch
    registerWorkspaceTargets([{ id: 'alpha', label: 'Alpha', baseUrl: '/ws/alpha' }])
    selectWorkspace('alpha')
    setObserverSseInstanceId('inst-alpha.7')

    let fetchedSseUrl = ''
    let fetchedInstanceHeader: string | undefined
    let streamController: ReadableStreamDefaultController<Uint8Array> | null = null
    const mockSseFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      fetchedSseUrl = String(input)
      fetchedInstanceHeader = ((init?.headers ?? {}) as Record<string, string>)[OBSERVER_SSE_INSTANCE_HEADER]
      const stream = new ReadableStream<Uint8Array>({
        start(ctrl) { streamController = ctrl },
      })
      return new Response(stream, { status: 200, headers: { 'Content-Type': 'text/event-stream' } })
    }) as typeof fetch

    const received: unknown[] = []
    const ac = new AbortController()
    openViewSseStream('/api/v1/models/metrics/stream?window=1440&bucket_min=60', ac.signal, (f) => received.push(f), undefined, mockSseFetch)
    await flushUi(20)
    expect(fetchedSseUrl).toBe('/ws/alpha/api/v1/models/metrics/stream?window=1440&bucket_min=60')
    expect(fetchedInstanceHeader).toBe('inst-alpha.7')

    // Bump epoch BEFORE chunk arrives -> frame MUST be dropped!
    bumpSessionEpoch()
    streamController!.enqueue(new TextEncoder().encode('event: metrics\ndata: {"stale":true}\n\n'))
    await flushUi(20)
    expect(received).toHaveLength(0)
    ac.abort()
  })

  it('humanizes quota_rest causes, formats local release times, and groups/sorts/filters paused runtimes', () => {
    expect(quotaRestCauseMeta('provider_quota_refused')).toEqual({
      label: '한도 초과',
      shortLabel: '한도 초과',
      tone: 'warn',
    })
    expect(quotaRestCauseMeta('payment_refused')).toEqual({
      label: '결제·크레딧 거절',
      shortLabel: '결제 거절',
      tone: 'bad',
    })
    expect(quotaRestCauseMeta('usage_read')).toEqual({
      label: '사용량 100% 도달',
      shortLabel: '사용량 100%',
      tone: 'warn',
    })
    expect(quotaRestCauseMeta('custom_cap')).toEqual({
      label: '일시 중지 (custom_cap)',
      shortLabel: '일시 중지 (custom_cap)',
      tone: 'warn',
    })

    const baseLocal = new Date(2026, 10, 26, 10, 0, 0).getTime() / 1000
    const sameDayTarget = new Date(2026, 10, 26, 10, 33, 0).getTime() / 1000
    const nextDayTarget = new Date(2026, 10, 27, 9, 5, 0).getTime() / 1000
    const multiDayTarget = new Date(2026, 10, 28, 14, 28, 0).getTime() / 1000

    expect(formatLocalReleaseTime(sameDayTarget, baseLocal)).toBe('오늘 10:33')
    expect(formatLocalReleaseTime(nextDayTarget, baseLocal)).toBe('내일 09:05')
    expect(formatLocalReleaseTime(multiDayTarget, baseLocal)).toBe('11/28 14:28')
    expect(formatLocalReleaseTime(0, baseLocal)).toBeNull()
    expect(formatLocalReleaseTime(Number.NaN, baseLocal)).toBeNull()

    const soonSummary = formatReleaseSummary(baseLocal + 300, false, baseLocal)
    expect(soonSummary.countdown).toBe('5분 후')
    expect(soonSummary.isSoon).toBe(true)
    expect(soonSummary.isEstimated).toBe(true)

    expect(stripProviderPrefix('claude_code_acct:claude-opus', 'claude_code_acct')).toBe('claude-opus')
    expect(stripProviderPrefix('openai_codex.gpt-5', 'openai_codex')).toBe('gpt-5')
    expect(stripProviderPrefix('plain-id', 'other')).toBe('plain-id')

    const mkRt = (
      id: string,
      provider: string,
      model: string,
      quotaRest: RuntimeResolution['quota_rest'],
      isDefault = false,
    ): RuntimeResolution => ({
      id,
      provider,
      provider_id: provider,
      model,
      effective_max_context: 200_000,
      max_context_source: 'capability',
      max_output_tokens: 16_384,
      is_local: false,
      is_default: isDefault,
      quota_rest: quotaRest,
    })

    const runtimes: RuntimeResolution[] = [
      mkRt('claude_a:opus', 'claude_a', 'claude-opus', { cause: 'provider_quota_refused', reset_stated: true, until: baseLocal + 172_800 }),
      mkRt('claude_a:sonnet', 'claude_a', 'claude-sonnet', { cause: 'provider_quota_refused', reset_stated: true, until: baseLocal + 172_800 }),
      mkRt('claude_a:haiku', 'claude_a', 'claude-haiku', { cause: 'usage_read', reset_stated: true, until: baseLocal + 180_000 }),
      mkRt('codex:gpt5', 'codex', 'gpt-5-codex', { cause: 'provider_quota_refused', reset_stated: true, until: baseLocal + 300 }, true),
      mkRt('codex:mini', 'codex', 'gpt-5-mini', null),
      mkRt('gemini:pro', 'gemini', 'gemini-pro', { cause: 'payment_refused', reset_stated: false, until: baseLocal + 420 }),
      mkRt('gemini:flash', 'gemini', 'gemini-flash', { cause: 'provider_quota_refused', reset_stated: true, until: baseLocal + 900 }),
      mkRt('ollama:local', 'ollama', 'qwen', null),
    ]

    const displayNames = new Map([
      ['claude_a', 'Claude Code A'],
      ['codex', 'OpenAI Codex'],
      ['gemini', 'Gemini API'],
    ])
    const emails = new Map([
      ['codex', { integration_id: 'codex', state: 'read' as const, email: 'ops@example.com', plan: ['Pro'] }],
    ])

    // Default sort ('release'): soonest until first -> codex (300s), gemini (420s), claude_a (172800s)
    const byRelease = groupRestingRuntimes(runtimes, {
      providerDisplayNames: displayNames,
      accountEmails: emails,
      sortBy: 'release',
      causeFilter: 'all',
      nowUnix: baseLocal,
    })
    expect(byRelease.summary.totalRegistered).toBe(8)
    expect(byRelease.summary.restingCount).toBe(6)
    expect(byRelease.summary.availableCount).toBe(2)
    expect(byRelease.summary.groupCount).toBe(3)
    expect(byRelease.summary.hasPaymentRefused).toBe(true)
    expect(byRelease.summary.soonestUntil).toBe(baseLocal + 300)
    expect(byRelease.groups.map((g) => g.provider)).toEqual(['codex', 'gemini', 'claude_a'])
    expect(byRelease.groups[0]!.restingCount).toBe(1)
    expect(byRelease.groups[0]!.totalInProvider).toBe(2)
    expect(byRelease.groups[0]!.accountLineText).toBe('ops@example.com · Pro')
    // payment_refused wins primaryCause precedence on mixed gemini group
    expect(byRelease.groups[1]!.primaryCause).toBe('payment_refused')
    expect(byRelease.groups[1]!.hasEstimatedReset).toBe(true)

    // Sort by count desc -> claude_a (3), gemini (2), codex (1)
    const byCount = groupRestingRuntimes(runtimes, {
      providerDisplayNames: displayNames,
      sortBy: 'count',
      causeFilter: 'all',
      nowUnix: baseLocal,
    })
    expect(byCount.groups.map((g) => g.provider)).toEqual(['claude_a', 'gemini', 'codex'])

    // Sort by name -> Claude Code A, Gemini API, OpenAI Codex
    const byName = groupRestingRuntimes(runtimes, {
      providerDisplayNames: displayNames,
      sortBy: 'name',
      causeFilter: 'all',
      nowUnix: baseLocal,
    })
    expect(byName.groups.map((g) => g.provider)).toEqual(['claude_a', 'gemini', 'codex'])

    // Cause filter ('payment_refused') keeps only gemini and only its payment_refused runtime
    const onlyPayment = groupRestingRuntimes(runtimes, {
      providerDisplayNames: displayNames,
      sortBy: 'release',
      causeFilter: 'payment_refused',
      nowUnix: baseLocal,
    })
    expect(onlyPayment.groups).toHaveLength(1)
    expect(onlyPayment.groups[0]!.provider).toBe('gemini')
    expect(onlyPayment.groups[0]!.runtimes).toHaveLength(1)
    expect(onlyPayment.summary.restingCount).toBe(6)
  })

  it('renders collapsible grouped Paused Runtimes panel on Quotas tab with expand, filter, sort, and KPI counts', async () => {
    const nowSec = Math.floor(Date.now() / 1000)
    const mkRt = (
      id: string,
      provider: string,
      model: string,
      quotaRest: RuntimeResolution['quota_rest'],
      isDefault = false,
    ): RuntimeResolution => ({
      id,
      provider,
      provider_id: provider,
      model,
      effective_max_context: 200_000,
      max_context_source: 'capability',
      max_output_tokens: 16_384,
      is_local: false,
      is_default: isDefault,
      quota_rest: quotaRest,
    })

    const runtimes: RuntimeResolution[] = [
      mkRt('claude_acct:opus', 'claude_acct', 'claude-opus-4', { cause: 'provider_quota_refused', reset_stated: true, until: nowSec + 172_800 }),
      mkRt('claude_acct:sonnet', 'claude_acct', 'claude-sonnet-4', { cause: 'provider_quota_refused', reset_stated: false, until: nowSec + 180_000 }),
      mkRt('claude_acct:haiku', 'claude_acct', 'claude-haiku-4', { cause: 'provider_quota_refused', reset_stated: true, until: nowSec + 172_800 }),
      mkRt('codex_acct:gpt5', 'codex_acct', 'gpt-5-codex', { cause: 'provider_quota_refused', reset_stated: true, until: nowSec + 300 }, true),
      mkRt('codex_acct:mini', 'codex_acct', 'gpt-5-mini', null),
      mkRt('gemini_acct:pro', 'gemini_acct', 'gemini-2.5-pro', { cause: 'payment_refused', reset_stated: false, until: nowSec + 420 }),
      mkRt('gemini_acct:flash', 'gemini_acct', 'gemini-2.5-flash', { cause: 'payment_refused', reset_stated: false, until: nowSec + 480 }),
      mkRt('local_acct:qwen', 'local_acct', 'qwen-local', null),
    ]

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.startsWith('/api/v1/runtime/resolved')) {
        return jsonResponse({
          config_path: 'runtime.toml',
          default_route: 'default',
          default_runtime: runtimes[3],
          runtimes,
          lanes: [],
          assignments: [],
          provider_usage_windows: [],
        })
      }
      if (url.startsWith('/api/v1/dashboard/provider-usage-history')) {
        return jsonResponse({ state: 'unavailable', reason: 'no history' })
      }
      if (url.startsWith('/api/v1/setup/inventory')) {
        return jsonResponse({
          integrations: [
            { id: 'claude_acct', display_name: 'Claude Code Alpha', setup_support: 'full' },
            { id: 'codex_acct', display_name: 'Codex CLI Alpha', setup_support: 'full' },
            { id: 'gemini_acct', display_name: 'Gemini API Alpha', setup_support: 'full' },
          ],
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    const onNavigate = vi.fn()
    render(
      html`<${RuntimeWorkspace} subroute="quotas" onNavigate=${onNavigate} onInspect=${vi.fn()} />`,
      container,
    )

    const panel = await vi.waitFor(() => {
      const p = container.querySelector('[data-testid="paused-runtimes-panel"]')
      expect(p).not.toBeNull()
      return p!
    })

    // KPI 4 shows resting/registered and available counts, red tone due to payment_refused
    const kpi4 = container.querySelector('[data-testid="kpi-paused-runtimes"]')!
    expect(kpi4.textContent).toContain('일시 중지 런타임')
    expect(kpi4.textContent).toContain('6 / 8')
    expect(kpi4.textContent).toContain('가용 2')
    expect(kpi4.querySelector('.ov-kpi-v.bad')).not.toBeNull()

    // Provider groups rendered in soonest-release order and collapsed by default
    const groupEls = Array.from(panel.querySelectorAll('[data-testid^="paused-group-"]')).filter(
      (el) => !el.getAttribute('data-testid')?.startsWith('paused-group-body-'),
    )
    expect(groupEls.map((el) => el.getAttribute('data-testid'))).toEqual([
      'paused-group-codex_acct',
      'paused-group-gemini_acct',
      'paused-group-claude_acct',
    ])
    expect(panel.querySelector('[data-testid="paused-group-body-gemini_acct"]')).toBeNull()
    expect(panel.textContent).toContain('결제·크레딧 거절')
    expect(panel.textContent).toContain('한도 초과')
    expect(panel.textContent).toContain('1/2 중지')
    // Group header with provider-stated soonestUntil does NOT falsely tag 예상 even if a later runtime is unstated
    expect(panel.querySelector('[data-testid="paused-group-claude_acct"]')?.textContent).not.toContain('예상')
    expect(panel.querySelector('[data-testid="paused-group-gemini_acct"]')?.textContent).toContain('예상')

    // Expanding gemini_acct reveals individual runtimes, local time, 예상 tag, and API 키 등록 action
    const geminiBtn = panel.querySelector('[data-testid="paused-group-gemini_acct"] button[aria-expanded]') as HTMLButtonElement
    geminiBtn.click()
    await flushUi(10)
    const geminiBody = panel.querySelector('[data-testid="paused-group-body-gemini_acct"]')
    expect(geminiBody).not.toBeNull()
    expect(geminiBody!.textContent).toContain('gemini-2.5-pro')
    expect(geminiBody!.textContent).toContain('예상')
    expect(geminiBody!.textContent).toContain('API 키 등록')

    // Sort switch to count -> claude_acct (3) first
    const sortCountBtn = panel.querySelector('[data-testid="paused-sort-count"]') as HTMLButtonElement
    sortCountBtn.click()
    await flushUi(10)
    const sortedGroupIds = Array.from(panel.querySelectorAll('[data-testid^="paused-group-"]'))
      .map((el) => el.getAttribute('data-testid'))
      .filter((id) => id && !id.startsWith('paused-group-body-'))
    expect(sortedGroupIds).toEqual([
      'paused-group-claude_acct',
      'paused-group-gemini_acct',
      'paused-group-codex_acct',
    ])

    // Cause filter to payment_refused -> shows only gemini_acct
    const paymentFilterBtn = panel.querySelector('[data-testid="paused-filter-payment_refused"]') as HTMLButtonElement
    paymentFilterBtn.click()
    await flushUi(10)
    expect(panel.querySelector('[data-testid="paused-group-gemini_acct"]')).not.toBeNull()
    expect(panel.querySelector('[data-testid="paused-group-claude_acct"]')).toBeNull()

    // Collapse entire panel -> renders compact 1-line summary and hides group list
    const panelToggle = panel.querySelector('[data-testid="paused-panel-toggle"]') as HTMLButtonElement
    panelToggle.click()
    await flushUi(10)
    expect(panelToggle.getAttribute('aria-expanded')).toBe('false')
    expect(panel.textContent).toContain('일시 중지 6/8 (3개 계정) · 가용 2')
    expect(panel.querySelector('[data-testid="paused-group-gemini_acct"]')).toBeNull()
  })
})
