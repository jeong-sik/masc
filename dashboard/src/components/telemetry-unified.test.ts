import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { TelemetryResponse, TelemetrySummaryResponse } from '../api/dashboard'

void vi

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
    fetchDashboardShell?: (args?: { signal?: AbortSignal }) => Promise<unknown>
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
    fetchDashboardNamespaceTruth: opts?.fetchDashboardNamespaceTruth ?? vi.fn().mockResolvedValue({ execution: { summary: { active_sessions: 1, active_operations: 3, continuity_alerts: 0 } } }),
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

  it('renders runtime diagnosis metadata for operators', async () => {
    const fetchTelemetry = vi.fn().mockResolvedValue(baseTelemetry)
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(baseSummary)
    const { TelemetryUnified } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('Runtime Diagnosis')
    expect(container.textContent).toContain('MASC telemetry store')
    expect(container.textContent).toContain('Refresh')
    expect(container.textContent).toContain('30초 자동 갱신')
    expect(container.textContent).toContain('MASC telemetry store entries')
    expect(container.textContent).toContain('mcp__masc__masc_status')

    // MASC Store Diagnosis cards (live state)
    expect(container.textContent).toContain('Keeper 현황 (live)')
    expect(container.textContent).toContain('Tool 등록 현황 (live)')
    expect(container.textContent).toContain('Agent 현황 (live)')
    expect(container.textContent).toContain('1 활성 세션')
    expect(container.textContent).toContain('5 public')
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

    expect(container.textContent).toContain('반복 그룹 1개 · 원본 3건')
    expect(container.textContent).toContain('Polling / no-op')
    expect(container.textContent).toContain('Polling / no-op · masc_status · 3 events')
    expect(container.textContent).toContain('task_claimed: keeper-alpha')
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
      label: 'keeper-heart heartbeat',
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

    expect(container.textContent).toContain('Heartbeat · keeper-heart heartbeat · 2 events')
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

    const groupRow = Array.from(container.querySelectorAll('[role="button"]'))
      .find(node => node.textContent?.includes('Polling / no-op · masc_status · 3 events'))
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
    expect(container.textContent).toContain('Raw JSON')
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
    const fetchDashboardNamespaceTruth = createAbortableResponse({ execution: { summary: { active_sessions: 1, active_operations: 3, continuity_alerts: 0 } } })
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
