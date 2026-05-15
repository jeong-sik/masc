import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { TelemetryResponse, TelemetrySummaryResponse } from '../api/dashboard'

void vi
vi.setConfig({ testTimeout: 120_000 })

const baseTelemetry: TelemetryResponse = {
  generated_at: '2026-04-09T05:10:00Z',
  count: 1,
  entries: [
    {
      source: 'tool_metric',
      ts: 1_775_709_000,
      tool_name: 'mcp__masc__masc_status',
      duration_ms: 42,
      success: true,
    },
  ],
}

const baseSummary: TelemetrySummaryResponse = {
  generated_at: '2026-04-09T05:10:00Z',
  sources: [
    {
      source: 'tool_metric',
      entry_count: 1,
      keeper_count: 1,
      exists: true,
      producer: 'Telemetry_unified.summary_json',
      durable_store: '.masc/tool_metrics/YYYY-MM/DD.jsonl',
      dashboard_surface: '/api/v1/dashboard/telemetry/summary',
      freshness_slo_s: 300,
      latest_age_s: 45,
      health: 'stale',
      stale_reason: 'freshness_slo_exceeded',
    },
  ],
  total_entries: 1,
}

async function flushUi(): Promise<void> {
  await act(async () => {
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
      await vi.advanceTimersByTimeAsync(0)
    }
  })
}

function requireResolver<T>(
  resolver: ((value: T) => void) | null,
  label: string,
): (value: T) => void {
  if (!resolver) {
    throw new Error(label)
  }
  return resolver
}

async function loadPanel(
  fetchTelemetry: (opts?: { signal?: AbortSignal }) => Promise<TelemetryResponse>,
  fetchTelemetrySummary: (opts?: { signal?: AbortSignal }) => Promise<TelemetrySummaryResponse>,
  opts?: {
    fetchDashboardShell?: (args?: { light?: boolean; signal?: AbortSignal }) => Promise<unknown>
    fetchDashboardTools?: (args?: { signal?: AbortSignal }) => Promise<unknown>
    fetchDashboardNamespaceTruth?: (args?: { signal?: AbortSignal }) => Promise<unknown>
  },
) {
  vi.resetModules()
  vi.doMock('../api/dashboard', () => ({
    fetchTelemetry,
    fetchTelemetrySummary,
    fetchDashboardShell: opts?.fetchDashboardShell ?? vi.fn().mockResolvedValue({ counts: { keepers: 2, agents: 0, tasks: 5 }, status: { version: '0.2.0', build: { uptime_seconds: 600 } } }),
    fetchDashboardTools: opts?.fetchDashboardTools ?? vi.fn().mockResolvedValue({ tool_inventory: { count: 10, tools: [], surface_summary: { public_mcp: { count: 5, tools: [] } } }, tool_usage: { total_calls: 100, never_called_count: 0 } }),
    fetchDashboardNamespaceTruth: opts?.fetchDashboardNamespaceTruth ?? vi.fn().mockResolvedValue({ execution: { summary: { active_operations: 3, blocked_operations: 1, continuity_alerts: 0 } } }),
  }))
  return import('./telemetry-unified')
}

describe('TelemetryUnified', () => {
  let container: HTMLDivElement
  const originalVisibility = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState')

  beforeEach(() => {
    vi.useFakeTimers()
    container = document.createElement('div')
    document.body.appendChild(container)
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => 'visible',
    })
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    window.location.hash = ''
    vi.clearAllMocks()
    vi.resetModules()
    vi.doUnmock('../api/dashboard')
    vi.useRealTimers()
    if (originalVisibility) {
      Object.defineProperty(document, 'visibilityState', originalVisibility)
    }
  })

  it('polls automatically while the document is visible', async () => {
    const fetchTelemetry = vi.fn().mockResolvedValue(baseTelemetry)
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(baseSummary)
    const { TelemetryUnified } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchTelemetry).toHaveBeenCalledTimes(1)
    expect(fetchTelemetrySummary).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(30_000)
    await flushUi()

    expect(fetchTelemetry).toHaveBeenCalledTimes(2)
    expect(fetchTelemetrySummary).toHaveBeenCalledTimes(2)
  })

  it('debounces server-side telemetry filter changes', async () => {
    const fetchTelemetry = vi.fn().mockResolvedValue(baseTelemetry)
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(baseSummary)
    const { TelemetryUnified } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchTelemetry).toHaveBeenCalledTimes(1)

    const keeperInput = container.querySelector<HTMLInputElement>('input[aria-label="키퍼 이름 필터"]')
    expect(keeperInput).toBeTruthy()

    await act(async () => {
      if (!keeperInput) return
      keeperInput.value = 's'
      keeperInput.dispatchEvent(new Event('input', { bubbles: true }))
      keeperInput.value = 'sa'
      keeperInput.dispatchEvent(new Event('input', { bubbles: true }))
      keeperInput.value = 'sangsu'
      keeperInput.dispatchEvent(new Event('input', { bubbles: true }))
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchTelemetry).toHaveBeenCalledTimes(1)

    await act(async () => {
      await vi.advanceTimersByTimeAsync(249)
    })
    await flushUi()

    expect(fetchTelemetry).toHaveBeenCalledTimes(1)

    await act(async () => {
      await vi.advanceTimersByTimeAsync(1)
    })
    await flushUi()

    expect(fetchTelemetry).toHaveBeenCalledTimes(2)
    expect(fetchTelemetry.mock.calls[1]?.[0]).toMatchObject({ keeper: 'sangsu' })
  })

  it('surfaces summary fetch errors to the panel error banner (regression: Phase 0 fleet-data-core)', async () => {
    // Before Phase 0, telemetry-unified awaited fetchTelemetrySummary directly
    // inside Promise.all, so any rejection flowed to the outer catch and set
    // state.error. Phase 0 moved the fetch into fleet-data-core which swallows
    // the rejection into sharedTelemetrySummaryError; the panel must re-surface
    // that to preserve the prior user-visible failure UI.
    const fetchTelemetry = vi.fn().mockResolvedValue(baseTelemetry)
    const fetchTelemetrySummary = vi.fn().mockRejectedValue(
      new Error('GET /api/v1/dashboard/telemetry/summary: 503 Service Unavailable'),
    )
    const { TelemetryUnified } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchTelemetrySummary).toHaveBeenCalled()
    expect(container.textContent).toContain('503 Service Unavailable')
  })

  it('renders runtime diagnosis metadata for operators', async () => {
    const fetchTelemetry = vi.fn().mockResolvedValue(baseTelemetry)
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(baseSummary)
    const { TelemetryUnified } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('런타임 진단')
    expect(container.textContent).toContain('MASC telemetry store')
    expect(container.textContent).toContain('Refresh')
    expect(container.textContent).toContain('Auto-refresh 30s')
    expect(container.textContent).toContain('MASC telemetry store entries')
    expect(container.textContent).toContain('mcp__masc__masc_status')
    expect(container.textContent).toContain('freshness_slo_exceeded')
    expect(container.textContent).toContain('Telemetry_unified.summary_json')
    expect(container.textContent).toContain('.masc/tool_metrics/YYYY-MM/DD.jsonl')
    expect(container.textContent).toContain('/api/v1/dashboard/telemetry/summary')

    // MASC Store Diagnosis cards (live state)
    expect(container.textContent).toContain('키퍼 현황 (실시간)')
    expect(container.textContent).toContain('도구 등록 현황 (실시간)')
    expect(container.textContent).toContain('에이전트 현황 (실시간)')
    expect(container.textContent).toContain('3 활성 작업')
    expect(container.textContent).toContain('1 차단 작업')
    expect(container.textContent).not.toContain('활성 세션')
    expect(container.textContent).toContain('5 public')
  })

  it('renders telemetry summary coverage gap provenance', async () => {
    const fetchTelemetry = vi.fn().mockResolvedValue(baseTelemetry)
    const fetchTelemetrySummary = vi.fn().mockResolvedValue({
      ...baseSummary,
      sources: [
        {
          ...baseSummary.sources[0],
          health: 'coverage_gap',
          stale_reason: 'append_failed',
          coverage_gap_count: 1,
          coverage_gaps: [
            {
              schema: 'masc.telemetry_coverage_gap.v1',
              source: 'tool_metric',
              producer: 'telemetry_eio',
              durable_store: '.masc/telemetry',
              dashboard_surface: '/api/v1/dashboard/telemetry/summary',
              stale_reason: 'append_failed',
              trace_id: 'trace-summary-gap',
              error: 'disk full',
            },
          ],
        },
      ],
    })
    const { TelemetryUnified } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('coverage gaps 1: append_failed')
    expect(container.textContent).toContain('gap producer')
    expect(container.textContent).toContain('telemetry_eio')
    expect(container.textContent).toContain('gap store')
    expect(container.textContent).toContain('.masc/telemetry')
    expect(container.textContent).toContain('gap surface')
    expect(container.textContent).toContain('/api/v1/dashboard/telemetry/summary')
    expect(container.textContent).toContain('gap trace')
    expect(container.textContent).toContain('trace-summary-gap')
    expect(container.textContent).toContain('gap error')
    expect(container.textContent).toContain('disk full')
  })

  it('hydrates telemetry scope and entry focus from route params', async () => {
    window.location.hash = '#monitoring?section=fleet-health&view=event-log&session_id=sess-route&operation_id=op-route&worker_run_id=wr-route&q=turn-9'
    const fetchTelemetry = vi.fn().mockResolvedValue({
      ...baseTelemetry,
      count: 2,
      entries: [
        {
          source: 'tool_metric',
          ts: 1_775_709_100,
          session_id: 'sess-route',
          operation_id: 'op-route',
          worker_run_id: 'wr-route',
          tool_name: 'turn-9-evidence',
          duration_ms: 22,
          success: true,
        },
        {
          source: 'keeper_metric',
          ts: 1_775_709_000,
          session_id: 'sess-route',
          name: 'keeper-other',
          channel: 'turn_end',
          tool_call_count: 1,
        },
      ],
    })
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(baseSummary)
    const { TelemetryUnified } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchTelemetry).toHaveBeenCalledWith(expect.objectContaining({
      session_id: 'sess-route',
      operation_id: 'op-route',
      worker_run_id: 'wr-route',
      n: 100,
    }))
    expect(container.textContent).toContain('session sess-route')
    expect(container.textContent).toContain('operation op-route')
    expect(container.textContent).toContain('worker_run wr-route')
    expect(container.textContent).toContain('focus turn-9')
    expect(container.querySelector('[data-testid="telemetry-route-focus"]')).not.toBeNull()
    expect(container.textContent).toContain('SESSION sess-route')
    expect(container.textContent).toContain('OPERATION op-route')
    expect(container.textContent).toContain('WORKER wr-route')
    expect(container.textContent).toContain('QUERY turn-9')
    expect(container.textContent).toContain('1 focused item')
    const searchInput = container.querySelector<HTMLInputElement>('input[aria-label="엔트리 텍스트 검색"]')
    expect(searchInput?.value).toBe('turn-9')
    expect(container.textContent).toContain('검색 매치 1건')
    expect(container.textContent).toContain('turn-9-evidence')
    expect(container.textContent).not.toContain('keeper-other')
    expect(container.querySelectorAll('[data-route-focused-telemetry="true"]')).toHaveLength(1)

    const clearButton = Array.from(container.querySelectorAll<HTMLButtonElement>('button'))
      .find(button => button.textContent?.includes('CLEAR'))
    expect(clearButton).not.toBeUndefined()
    await act(async () => {
      clearButton!.click()
    })

    expect(window.location.hash).toContain('#monitoring?section=fleet-health&view=event-log')
    expect(window.location.hash).not.toContain('session_id=')
    expect(window.location.hash).not.toContain('operation_id=')
    expect(window.location.hash).not.toContain('worker_run_id=')
    expect(window.location.hash).not.toContain('q=')
  })

  it('renders a telemetry entry raw JSON copy action', async () => {
    const fetchTelemetry = vi.fn().mockResolvedValue(baseTelemetry)
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(baseSummary)
    const { TelemetryUnified } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const copyButton = container.querySelector('[aria-label="텔레메트리 항목 JSON 복사"]') as HTMLButtonElement | null
    expect(copyButton).not.toBeNull()
    expect(copyButton?.getAttribute('title')).toBe('텔레메트리 항목 JSON 복사')
  })

  it('surfaces a raw JSON copy action inside an expanded telemetry entry', async () => {
    const fetchTelemetry = vi.fn().mockResolvedValue(baseTelemetry)
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(baseSummary)
    const { TelemetryUnified } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const rowToggle = container.querySelector('button[aria-expanded="false"]') as HTMLButtonElement | null
    expect(rowToggle).not.toBeNull()
    await act(async () => {
      rowToggle?.click()
      await Promise.resolve()
    })
    await flushUi()

    const expandedCopyButton = container.querySelector('[aria-label="펼친 텔레메트리 항목 JSON 복사"]') as HTMLButtonElement | null
    expect(expandedCopyButton).not.toBeNull()
    expect(expandedCopyButton?.getAttribute('title')).toBe('펼친 텔레메트리 항목 JSON 복사')
  })

  it('condenses consecutive noisy telemetry into grouped categories', async () => {
    const fetchTelemetry = vi.fn().mockResolvedValue({
      ...baseTelemetry,
      count: 4,
      entries: [
        {
          source: 'tool_metric',
          ts: 1_775_709_300,
          session_id: 'sess-1',
          tool_name: 'mcp__masc__masc_status',
          duration_ms: 15,
          success: true,
        },
        {
          source: 'tool_usage',
          ts: 1_775_709_299,
          session_id: 'sess-1',
          caller: 'keeper_internal',
          tool_name: 'masc_status',
        },
        {
          source: 'tool_call_io',
          ts: 1_775_709_298,
          session_id: 'sess-1',
          keeper: 'keeper-alpha',
          tool: 'masc_status',
        },
        {
          source: 'agent_event',
          ts: 1_775_709_200,
          event: ['task_claimed', { agent_id: 'keeper-alpha' }],
        },
      ],
    })
    const fetchTelemetrySummary = vi.fn().mockResolvedValue({
      ...baseSummary,
      sources: [
        { source: 'tool_metric', entry_count: 1, keeper_count: 1, exists: true },
        { source: 'tool_usage', entry_count: 1, keeper_count: 1, exists: true },
        { source: 'tool_call_io', entry_count: 1, keeper_count: 1, exists: true },
        { source: 'agent_event', entry_count: 1, keeper_count: 1, exists: true },
      ],
      total_entries: 4,
    })
    const { TelemetryUnified, buildTelemetryDisplayItems } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    const displayItems = buildTelemetryDisplayItems((await fetchTelemetry()).entries)
    expect(displayItems[0]).toMatchObject({
      kind: 'group',
      category: 'polling',
      label: 'masc_status',
      count: 3,
    })
    expect(displayItems[1]).toMatchObject({
      kind: 'entry',
    })

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('접힌 그룹 1개 · 원본 3건')
    expect(container.textContent).toContain('폴링 / 무동작')
    expect(container.textContent).toContain('폴링 / 무동작 · masc_status · 3 events')
    expect(container.textContent).toContain('task_claimed: keeper-alpha')

    const groupToggle = Array.from(container.querySelectorAll('button[aria-expanded="false"]'))
      .find(button => button.textContent?.includes('폴링 / 무동작')) as HTMLButtonElement | undefined
    expect(groupToggle).toBeTruthy()
    await act(async () => {
      groupToggle?.click()
      await Promise.resolve()
    })
    await flushUi()

    const expandedCopyButton = container.querySelector('[aria-label="펼친 텔레메트리 그룹 JSON 복사"]') as HTMLButtonElement | null
    expect(expandedCopyButton).not.toBeNull()
    expect(expandedCopyButton?.getAttribute('title')).toBe('펼친 텔레메트리 그룹 JSON 복사')
  })

  it('groups heartbeat keeper metrics into a heartbeat category', async () => {
    const fetchTelemetry = vi.fn().mockResolvedValue({
      ...baseTelemetry,
      count: 3,
      entries: [
        {
          source: 'keeper_metric',
          ts: 1_775_709_310,
          name: 'keeper-heart',
          channel: 'heartbeat',
          session_id: 'sess-heart',
          model_used: 'unknown',
          tool_call_count: 0,
        },
        {
          source: 'keeper_metric',
          ts: 1_775_709_309,
          name: 'keeper-heart',
          channel: 'heartbeat',
          session_id: 'sess-heart',
          model_used: 'unknown',
          tool_call_count: 0,
        },
        {
          source: 'keeper_metric',
          ts: 1_775_709_200,
          name: 'keeper-heart',
          channel: 'turn',
          model_used: 'glm-5.1',
          tool_call_count: 1,
        },
      ],
    })
    const fetchTelemetrySummary = vi.fn().mockResolvedValue({
      ...baseSummary,
      sources: [
        { source: 'keeper_metric', entry_count: 3, keeper_count: 1, exists: true },
      ],
      total_entries: 3,
    })
    const { TelemetryUnified, buildTelemetryDisplayItems } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    const displayItems = buildTelemetryDisplayItems((await fetchTelemetry()).entries)
    expect(displayItems[0]).toMatchObject({
      kind: 'group',
      category: 'heartbeat',
      label: 'fleet heartbeat',
      count: 2,
    })
    expect(displayItems[1]).toMatchObject({
      kind: 'entry',
    })

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('하트비트 · fleet heartbeat · 2 events')
    expect(container.textContent).not.toContain('model=glm-5.1')
  })

  it('collapses interleaved heartbeat + oas snapshot polling across multiple keepers into one group (#13002)', async () => {
    const { buildTelemetryDisplayItems } = await loadPanel(
      vi.fn().mockResolvedValue(baseTelemetry),
      vi.fn().mockResolvedValue(baseSummary),
    )
    // Reproduces the screenshot: 14 keepers each emit alternating
    // [oas_event masc:keeper:snapshot] + [keeper_metric heartbeat] within
    // the same 60s window, so the 100-entry stream is 100% polling and
    // real activity is invisible.  Expectation: one collapsed
    // 'fleet heartbeat' group plus the real entry.
    type Entry = Parameters<typeof buildTelemetryDisplayItems>[0][number]
    const keepers = Array.from({ length: 14 }, (_, i) => `keeper-${i}`)
    const polling: Entry[] = keepers.flatMap((name, i) => {
      const ts = 1_775_709_400 - i
      return [
        {
          source: 'oas_event' as const,
          ts,
          event_type: 'masc:keeper:snapshot',
          agent_name: name,
        },
        {
          source: 'keeper_metric' as const,
          ts,
          name,
          channel: 'heartbeat',
          model_used: '',
          tool_call_count: 0,
        },
      ]
    })
    const realActivity: Entry = {
      source: 'tool_call_io',
      ts: 1_775_709_500,
      keeper: 'keeper-3',
      tool: 'board_post',
    }

    const items = buildTelemetryDisplayItems([realActivity, ...polling])

    // The 28 polling rows must collapse to a single fleet-heartbeat group.
    const heartbeatGroups = items.filter(
      i => i.kind === 'group' && i.category === 'heartbeat',
    )
    expect(heartbeatGroups).toHaveLength(1)
    expect(heartbeatGroups[0]).toMatchObject({
      kind: 'group',
      category: 'heartbeat',
      label: 'fleet heartbeat',
      count: 28,
    })

    // Real activity entry must still surface.
    const realRow = items.find(
      i => i.kind === 'entry' && i.entry.source === 'tool_call_io',
    )
    expect(realRow).toBeTruthy()

    // Total visible rows = 1 fleet-heartbeat group + 1 real entry.
    expect(items).toHaveLength(2)
  })

  it('uses trajectory and execution receipt fields for telemetry previews', async () => {
    const { buildTelemetryDisplayItems, filterTelemetryDisplayItems } = await loadPanel(
      vi.fn().mockResolvedValue(baseTelemetry),
      vi.fn().mockResolvedValue(baseSummary),
    )

    const items = buildTelemetryDisplayItems([
      {
        source: 'trajectory_tool_call',
        ts: 1_775_709_300,
        session_id: 'sess-tool',
        keeper_name: 'keeper-alpha',
        tool_name: 'keeper_tasks_list',
      },
      {
        source: 'trajectory_tool_call',
        ts: 1_775_709_299,
        session_id: 'sess-tool',
        runtime_contract: { keeper_name: 'keeper-alpha' },
        action_radius: { tool_name: 'keeper_tasks_list' },
      },
      {
        source: 'execution_receipt',
        recorded_at: '2026-04-09T05:10:00Z',
        keeper_name: 'keeper-alpha',
        outcome: 'completed',
        terminal_reason_code: 'turn_done',
      },
    ])

    expect(items[0]).toMatchObject({
      kind: 'group',
      category: 'polling',
      label: 'keeper_tasks_list',
      count: 2,
    })
    expect(items[1]).toMatchObject({ kind: 'entry' })
    if (items[1]?.kind === 'entry') {
      expect(items[1].entry.source).toBe('execution_receipt')
    }
    const receiptMatches = filterTelemetryDisplayItems(items, 'turn_done')
    expect(receiptMatches).toHaveLength(1)
  })

  it('groups turn-scoped lifecycle, nested telemetry_event, and tool rows', async () => {
    const { buildTelemetryDisplayItems, filterTelemetryDisplayItems } = await loadPanel(
      vi.fn().mockResolvedValue(baseTelemetry),
      vi.fn().mockResolvedValue(baseSummary),
    )

    const items = buildTelemetryDisplayItems([
      {
        source: 'oas_event',
        ts_unix: 1_775_709_400,
        event_type: 'turn_ready',
        agent_name: 'keeper-alpha-agent',
        turn: 42,
      },
      {
        source: 'oas_event',
        ts_unix: 1_775_709_399,
        event_type: 'telemetry_event',
        payload: [
          'Context_window_usage',
          {
            agent_name: 'keeper-alpha-agent',
            turn: 42,
            estimated_tokens: 1234,
          },
        ],
      },
      {
        source: 'tool_call_io',
        ts: 1_775_709_398,
        keeper: 'alpha',
        tool: 'keeper_tasks_list',
        turn: 42,
        runtime_contract: {
          agent_name: 'keeper-alpha-agent',
        },
      },
      {
        source: 'oas_event',
        ts_unix: 1_775_709_397,
        event_type: 'telemetry_event',
        payload: [
          'Streaming_first_chunk',
          {
            provider: 'openai_compat',
            model: 'deepseek-v4-flash:cloud',
            ttfrc_ms: 1685,
          },
        ],
      },
    ])

    expect(items[0]).toMatchObject({
      kind: 'group',
      category: 'turn',
      label: 'keeper-alpha-agent · turn 42',
      count: 3,
    })
    expect(items[1]).toMatchObject({ kind: 'entry' })
    if (items[1]?.kind === 'entry') {
      expect(items[1].entry.source).toBe('oas_event')
      expect(items[1].entry.event_type).toBe('telemetry_event')
    }

    const contextMatches = filterTelemetryDisplayItems(items, 'Context_window_usage')
    expect(contextMatches).toHaveLength(1)
    expect(contextMatches[0]).toMatchObject({
      kind: 'group',
      category: 'turn',
    })

    const cloudMatches = filterTelemetryDisplayItems(items, 'deepseek-v4-flash:cloud')
    expect(cloudMatches).toHaveLength(1)
    expect(cloudMatches[0]).toMatchObject({ kind: 'entry' })
  })

  it('keeps turn groups separated by run scope (session_id / operation_id / worker_run_id)', async () => {
    const { buildTelemetryDisplayItems } = await loadPanel(
      vi.fn().mockResolvedValue(baseTelemetry),
      vi.fn().mockResolvedValue(baseSummary),
    )

    // Two different sessions reusing the same agent_name + turn number.
    // Without run-scope in the grouping key these collapse into one row;
    // with run-scope they MUST stay in two distinct groups.
    const items = buildTelemetryDisplayItems([
      {
        source: 'oas_event',
        ts_unix: 1_775_710_000,
        event_type: 'turn_ready',
        agent_name: 'keeper-alpha-agent',
        turn: 1,
        session_id: 'sess-foo',
      },
      {
        source: 'oas_event',
        ts_unix: 1_775_709_999,
        event_type: 'telemetry_event',
        session_id: 'sess-foo',
        payload: [
          'Context_window_usage',
          { agent_name: 'keeper-alpha-agent', turn: 1, estimated_tokens: 100 },
        ],
      },
      {
        source: 'oas_event',
        ts_unix: 1_775_709_998,
        event_type: 'turn_ready',
        agent_name: 'keeper-alpha-agent',
        turn: 1,
        session_id: 'sess-bar',
      },
      {
        source: 'oas_event',
        ts_unix: 1_775_709_997,
        event_type: 'telemetry_event',
        session_id: 'sess-bar',
        payload: [
          'Context_window_usage',
          { agent_name: 'keeper-alpha-agent', turn: 1, estimated_tokens: 200 },
        ],
      },
    ])

    const turnGroups = items.filter(
      (item): item is Extract<typeof item, { kind: 'group' }> =>
        item.kind === 'group' && item.category === 'turn',
    )
    expect(turnGroups).toHaveLength(2)
    expect(turnGroups[0]).toMatchObject({
      label: 'keeper-alpha-agent · turn 1',
      count: 2,
    })
    expect(turnGroups[1]).toMatchObject({
      label: 'keeper-alpha-agent · turn 1',
      count: 2,
    })
  })

  it('does not group on turn=0 sentinel (turn-not-tracked records stay as entries)', async () => {
    const { buildTelemetryDisplayItems } = await loadPanel(
      vi.fn().mockResolvedValue(baseTelemetry),
      vi.fn().mockResolvedValue(baseSummary),
    )

    // turn=0 is used by keeper telemetry as "turn not tracked" (e.g.,
    // trajectory tool-call records). These entries must not be collapsed
    // into a fake `actor · turn 0` group even when they share an actor.
    const items = buildTelemetryDisplayItems([
      {
        source: 'tool_call_io',
        ts: 1_775_711_000,
        keeper: 'alpha',
        tool: 'keeper_tasks_list',
        turn: 0,
        runtime_contract: { agent_name: 'keeper-alpha-agent' },
      },
      {
        source: 'tool_call_io',
        ts: 1_775_710_999,
        keeper: 'alpha',
        tool: 'masc_status',
        turn: 0,
        runtime_contract: { agent_name: 'keeper-alpha-agent' },
      },
      {
        source: 'oas_event',
        ts_unix: 1_775_710_998,
        event_type: 'telemetry_event',
        payload: [
          'Context_window_usage',
          { agent_name: 'keeper-alpha-agent', turn: 0, estimated_tokens: 50 },
        ],
      },
    ])

    const turnGroups = items.filter(
      (item): item is Extract<typeof item, { kind: 'group' }> =>
        item.kind === 'group' && item.category === 'turn',
    )
    expect(turnGroups).toHaveLength(0)
  })

  it('surfaces cloud Ollama provider details in OAS telemetry previews and search', async () => {
    const { buildTelemetryDisplayItems, filterTelemetryDisplayItems } = await loadPanel(
      vi.fn().mockResolvedValue(baseTelemetry),
      vi.fn().mockResolvedValue(baseSummary),
    )

    const items = buildTelemetryDisplayItems([
      {
        source: 'oas_event',
        ts_unix: 1_775_709_500,
        event_type: 'masc:oas_worker:build',
        agent_name: 'oas-tier-group.ollama_cloud_stable',
        payload: {
          agent: 'oas-tier-group.ollama_cloud_stable',
          provider_kind: 'openai_compat',
          model_id: 'kimi-k2.6:cloud',
          provider_model_id: 'kimi-k2.6:cloud',
          base_url: 'https://ollama.com/v1',
          endpoint: 'https://ollama.com/v1/chat/completions',
        },
      },
      {
        source: 'oas_event',
        ts_unix: 1_775_709_499,
        event_type: 'telemetry_event',
        payload: [
          'Streaming_summary',
          {
            provider: 'openai_compat',
            model: 'deepseek-v4-flash:cloud',
            total_ms: 3450,
          },
        ],
      },
    ])

    const buildMatches = filterTelemetryDisplayItems(items, 'ollama.com')
    expect(buildMatches).toHaveLength(1)
    expect(buildMatches[0]).toMatchObject({ kind: 'entry' })

    const streamingMatches = filterTelemetryDisplayItems(items, 'Streaming_summary')
    expect(streamingMatches).toHaveLength(1)
    expect(streamingMatches[0]).toMatchObject({ kind: 'entry' })

    const modelMatches = filterTelemetryDisplayItems(items, 'deepseek-v4-flash:cloud')
    expect(modelMatches).toHaveLength(1)
    expect(modelMatches[0]).toMatchObject({ kind: 'entry' })
  })

  it('expands grouped rows to reveal the condensed raw entries', async () => {
    const fetchTelemetry = vi.fn().mockResolvedValue({
      ...baseTelemetry,
      count: 3,
      entries: [
        {
          source: 'tool_metric',
          ts: 1_775_709_300,
          session_id: 'sess-2',
          tool_name: 'mcp__masc__masc_status',
          duration_ms: 15,
          success: true,
        },
        {
          source: 'tool_usage',
          ts: 1_775_709_299,
          session_id: 'sess-2',
          caller: 'keeper_internal',
          tool_name: 'masc_status',
        },
        {
          source: 'tool_call_io',
          ts: 1_775_709_298,
          session_id: 'sess-2',
          keeper: 'keeper-alpha',
          tool: 'masc_status',
        },
      ],
    })
    const fetchTelemetrySummary = vi.fn().mockResolvedValue({
      ...baseSummary,
      sources: [
        { source: 'tool_metric', entry_count: 1, keeper_count: 1, exists: true },
        { source: 'tool_usage', entry_count: 1, keeper_count: 1, exists: true },
        { source: 'tool_call_io', entry_count: 1, keeper_count: 1, exists: true },
      ],
      total_entries: 3,
    })
    const { TelemetryUnified } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const groupRow = Array.from(container.querySelectorAll('button'))
      .find(node => node.textContent?.includes('폴링 / 무동작 · masc_status · 3 events'))
    expect(groupRow).toBeTruthy()
    expect(groupRow?.getAttribute('aria-expanded')).toBe('false')

    await act(async () => {
      groupRow?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
      await Promise.resolve()
    })
    await flushUi()

    expect(groupRow?.getAttribute('aria-expanded')).toBe('true')
    expect(container.textContent).toContain('Latest:')
    expect(container.textContent).toContain('keeper-alpha -> masc_status')
    expect(container.textContent).toContain('원본 JSON')
  })

  it('keeps condensed keys stable when repeated no-timestamp groups reappear', async () => {
    const { buildTelemetryDisplayItems } = await loadPanel(
      vi.fn().mockResolvedValue(baseTelemetry),
      vi.fn().mockResolvedValue(baseSummary),
    )

    const items = buildTelemetryDisplayItems([
      {
        source: 'tool_usage',
        session_id: 'sess-a',
        caller: 'keeper_internal',
        tool_name: 'masc_status',
      },
      {
        source: 'agent_event',
        event: ['noop'],
      },
      {
        source: 'tool_usage',
        session_id: 'sess-a',
        caller: 'keeper_internal',
        tool_name: 'masc_status',
      },
    ])

    expect(items).toHaveLength(3)
    expect(items[0]?.kind).toBe('entry')
    expect(items[1]?.kind).toBe('entry')
    expect(items[2]?.kind).toBe('entry')
    const entryKeys = items.map(item => item.key)
    expect(new Set(entryKeys).size).toBe(entryKeys.length)
  })

  it('ignores unknown timestamps when computing grouped oldest timestamp', async () => {
    const { buildTelemetryDisplayItems } = await loadPanel(
      vi.fn().mockResolvedValue(baseTelemetry),
      vi.fn().mockResolvedValue(baseSummary),
    )

    const items = buildTelemetryDisplayItems([
      {
        source: 'tool_usage',
        session_id: 'sess-z',
        caller: 'keeper_internal',
        tool_name: 'masc_status',
      },
      {
        source: 'tool_usage',
        ts: 1_775_709_111,
        session_id: 'sess-z',
        caller: 'keeper_internal',
        tool_name: 'masc_status',
      },
    ])

    expect(items).toHaveLength(1)
    expect(items[0]).toMatchObject({
      kind: 'group',
      latestTs: 1_775_709_111,
      oldestTs: 1_775_709_111,
    })
  })

  it('ignores out-of-order telemetry refresh responses', async () => {
    let telemetryCall = 0
    let summaryCall = 0
    let resolveTelemetryFirst: ((value: TelemetryResponse) => void) | null = null
    let resolveTelemetrySecond: ((value: TelemetryResponse) => void) | null = null
    let resolveSummaryFirst: ((value: TelemetrySummaryResponse) => void) | null = null
    let resolveSummarySecond: ((value: TelemetrySummaryResponse) => void) | null = null

    const fetchTelemetry = vi.fn().mockImplementation(() => {
      telemetryCall += 1
      return new Promise<TelemetryResponse>(resolve => {
        if (telemetryCall === 1) resolveTelemetryFirst = resolve
        else resolveTelemetrySecond = resolve
      })
    })
    const fetchTelemetrySummary = vi.fn().mockImplementation(() => {
      summaryCall += 1
      return new Promise<TelemetrySummaryResponse>(resolve => {
        if (summaryCall === 1) resolveSummaryFirst = resolve
        else resolveSummarySecond = resolve
      })
    })
    const { TelemetryUnified } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const refreshButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('Refresh'))
    expect(refreshButton).toBeTruthy()

    await act(async () => {
      refreshButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
      await Promise.resolve()
    })

    const applyTelemetrySecond = requireResolver(resolveTelemetrySecond, 'missing second telemetry resolver')
    const applySummarySecond = requireResolver(resolveSummarySecond, 'missing second summary resolver')
    applyTelemetrySecond({
      ...baseTelemetry,
      entries: [{
        source: 'tool_metric',
        ts: 1_775_709_100,
        tool_name: 'newer_tool',
        duration_ms: 10,
        success: true,
      }],
    })
    applySummarySecond(baseSummary)
    await flushUi()

    expect(container.textContent).toContain('newer_tool')

    const applyTelemetryFirst = requireResolver(resolveTelemetryFirst, 'missing first telemetry resolver')
    const applySummaryFirst = requireResolver(resolveSummaryFirst, 'missing first summary resolver')
    applyTelemetryFirst({
      ...baseTelemetry,
      entries: [{
        source: 'tool_metric',
        ts: 1_775_709_000,
        tool_name: 'older_tool',
        duration_ms: 42,
        success: true,
      }],
    })
    applySummaryFirst(baseSummary)
    await flushUi()

    expect(container.textContent).toContain('newer_tool')
    expect(container.textContent).not.toContain('older_tool')
  })

  it('aborts superseded telemetry requests before starting a newer refresh', async () => {
    const abortedSignals: AbortSignal[] = []

    const createAbortableResponse = <T,>(value: T) => {
      let callCount = 0
      return vi.fn().mockImplementation((opts?: { signal?: AbortSignal }) => {
        callCount += 1
        if (callCount > 1) return Promise.resolve(value)
        return new Promise<T>((_resolve, reject) => {
          opts?.signal?.addEventListener('abort', () => {
            abortedSignals.push(opts.signal as AbortSignal)
            reject(new DOMException('superseded request', 'AbortError'))
          }, { once: true })
        })
      })
    }

    const fetchTelemetry = createAbortableResponse(baseTelemetry)
    const fetchTelemetrySummary = createAbortableResponse(baseSummary)
    const fetchDashboardShell = createAbortableResponse({ counts: { keepers: 2, agents: 0, tasks: 5 }, status: { version: '0.2.0', build: { uptime_seconds: 600 } } })
    const fetchDashboardTools = createAbortableResponse({ tool_inventory: { count: 10, tools: [], surface_summary: { public_mcp: { count: 5, tools: [] } } }, tool_usage: { total_calls: 100, never_called_count: 0 } })
    const fetchDashboardNamespaceTruth = createAbortableResponse({ execution: { summary: { active_operations: 3, blocked_operations: 1, continuity_alerts: 0 } } })
    const { TelemetryUnified } = await loadPanel(fetchTelemetry, fetchTelemetrySummary, {
      fetchDashboardShell,
      fetchDashboardTools,
      fetchDashboardNamespaceTruth,
    })

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const refreshButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('Refresh'))
    expect(refreshButton).toBeTruthy()

    await act(async () => {
      refreshButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchTelemetry).toHaveBeenCalledTimes(2)
    expect(fetchTelemetrySummary).toHaveBeenCalledTimes(2)
    expect(fetchDashboardShell).toHaveBeenCalledTimes(2)
    expect(fetchDashboardTools).toHaveBeenCalledTimes(2)
    expect(fetchDashboardNamespaceTruth).toHaveBeenCalledTimes(2)
    expect(abortedSignals.length).toBeGreaterThan(0)
    expect(abortedSignals.every(signal => signal.aborted)).toBe(true)
    expect(container.textContent).toContain('mcp__masc__masc_status')
  })
})

describe('filterTelemetryDisplayItems', () => {
  beforeEach(() => {
    // The outer describe enables fake timers globally; the pure-function
    // tests here don't need timers and dynamic import() resolves faster on
    // real timers, so opt out for this suite.
    vi.useRealTimers()
  })

  afterEach(() => {
    vi.resetModules()
    vi.doUnmock('../api/dashboard')
  })

  async function loadFilter() {
    return import('./telemetry-unified')
  }

  const sampleEntries = [
    {
      source: 'tool_metric' as const,
      ts: 1_775_709_300,
      session_id: 'sess-alpha',
      tool_name: 'mcp__masc__masc_status',
      duration_ms: 15,
      success: true,
    },
    {
      source: 'keeper_metric' as const,
      ts: 1_775_709_200,
      name: 'keeper-bravo',
      channel: 'turn_end',
      model_used: 'glm-4.6',
      tool_call_count: 2,
      success: true,
    },
    {
      source: 'agent_event' as const,
      ts: 1_775_709_100,
      event: ['task_claimed', { agent_id: 'keeper-charlie' }],
    },
    {
      source: 'tool_call_io' as const,
      ts: 1_775_709_000,
      operation_id: 'op-delta',
      keeper: 'keeper-delta',
      tool: 'masc_broadcast',
    },
  ]

  it('returns input reference unchanged for empty query', async () => {
    const { buildTelemetryDisplayItems, filterTelemetryDisplayItems } = await loadFilter()
    const items = buildTelemetryDisplayItems([...sampleEntries])
    expect(filterTelemetryDisplayItems(items, '')).toBe(items)
  })

  it('returns input reference unchanged for whitespace-only query', async () => {
    const { buildTelemetryDisplayItems, filterTelemetryDisplayItems } = await loadFilter()
    const items = buildTelemetryDisplayItems([...sampleEntries])
    expect(filterTelemetryDisplayItems(items, '   \t  ')).toBe(items)
  })

  it('trims query whitespace before matching', async () => {
    const { buildTelemetryDisplayItems, filterTelemetryDisplayItems } = await loadFilter()
    const items = buildTelemetryDisplayItems([...sampleEntries])
    const trimmed = filterTelemetryDisplayItems(items, '  keeper-bravo  ')
    const raw = filterTelemetryDisplayItems(items, 'keeper-bravo')
    expect(trimmed.length).toBe(raw.length)
    expect(trimmed.length).toBe(1)
  })

  it('is case-insensitive', async () => {
    const { buildTelemetryDisplayItems, filterTelemetryDisplayItems } = await loadFilter()
    const items = buildTelemetryDisplayItems([...sampleEntries])
    const upper = filterTelemetryDisplayItems(items, 'KEEPER-BRAVO')
    const lower = filterTelemetryDisplayItems(items, 'keeper-bravo')
    expect(upper.length).toBe(lower.length)
    expect(upper.length).toBe(1)
  })

  it('matches on the source field', async () => {
    const { buildTelemetryDisplayItems, filterTelemetryDisplayItems } = await loadFilter()
    const items = buildTelemetryDisplayItems([...sampleEntries])
    const filtered = filterTelemetryDisplayItems(items, 'agent_event')
    expect(filtered.length).toBe(1)
    expect(filtered[0]?.kind).toBe('entry')
    if (filtered[0]?.kind === 'entry') {
      expect(filtered[0].entry.source).toBe('agent_event')
    }
  })

  it('matches on preview text (tool name)', async () => {
    const { buildTelemetryDisplayItems, filterTelemetryDisplayItems } = await loadFilter()
    const items = buildTelemetryDisplayItems([...sampleEntries])
    const filtered = filterTelemetryDisplayItems(items, 'masc_broadcast')
    expect(filtered.length).toBe(1)
    if (filtered[0]?.kind === 'entry') {
      expect(filtered[0].entry.source).toBe('tool_call_io')
    }
  })

  it('matches on scope badge (operation_id)', async () => {
    const { buildTelemetryDisplayItems, filterTelemetryDisplayItems } = await loadFilter()
    const items = buildTelemetryDisplayItems([...sampleEntries])
    const filtered = filterTelemetryDisplayItems(items, 'op-delta')
    expect(filtered.length).toBe(1)
    if (filtered[0]?.kind === 'entry') {
      expect(filtered[0].entry.operation_id).toBe('op-delta')
    }
  })

  it('returns empty array when nothing matches', async () => {
    const { buildTelemetryDisplayItems, filterTelemetryDisplayItems } = await loadFilter()
    const items = buildTelemetryDisplayItems([...sampleEntries])
    const filtered = filterTelemetryDisplayItems(items, 'zzz-no-such-token')
    expect(filtered.length).toBe(0)
  })

  it('does not mutate input items', async () => {
    const { buildTelemetryDisplayItems, filterTelemetryDisplayItems } = await loadFilter()
    const items = buildTelemetryDisplayItems([...sampleEntries])
    const snapshot = items.map(item => item.key)
    filterTelemetryDisplayItems(items, 'keeper-bravo')
    expect(items.map(item => item.key)).toEqual(snapshot)
    expect(items.length).toBe(4)
  })

  it('handles entries with missing scope/preview fields without throwing', async () => {
    const { buildTelemetryDisplayItems, filterTelemetryDisplayItems } = await loadFilter()
    const sparseEntries = [
      {
        // agent_event with non-array event and no detail — tests sparse fields.
        source: 'agent_event' as const,
        ts: 1_775_709_500,
        event: 'heartbeat_tick',
      },
      {
        // tool_metric with no tool_name / duration — sparse preview.
        source: 'tool_metric' as const,
        ts: 1_775_709_400,
      },
    ]
    const items = buildTelemetryDisplayItems(sparseEntries)
    expect(() => filterTelemetryDisplayItems(items, 'anything')).not.toThrow()
    const matchesSource = filterTelemetryDisplayItems(items, 'tool_metric')
    expect(matchesSource.length).toBe(1)
  })

  it('matches group items on label (noisy tool name)', async () => {
    const { buildTelemetryDisplayItems, filterTelemetryDisplayItems } = await loadFilter()
    // Three consecutive masc_status entries collapse into a single group whose
    // label is the canonical tool name.
    const noisyEntries = [
      {
        source: 'tool_metric' as const,
        ts: 1_775_709_300,
        session_id: 'sess-noisy',
        tool_name: 'mcp__masc__masc_status',
        duration_ms: 10,
        success: true,
      },
      {
        source: 'tool_usage' as const,
        ts: 1_775_709_299,
        session_id: 'sess-noisy',
        caller: 'keeper_internal',
        tool_name: 'masc_status',
      },
      {
        source: 'tool_call_io' as const,
        ts: 1_775_709_298,
        session_id: 'sess-noisy',
        keeper: 'keeper-alpha',
        tool: 'masc_status',
      },
    ]
    const items = buildTelemetryDisplayItems(noisyEntries)
    expect(items[0]?.kind).toBe('group')
    const filtered = filterTelemetryDisplayItems(items, 'masc_status')
    expect(filtered.length).toBe(1)
    expect(filtered[0]?.kind).toBe('group')
  })
})
