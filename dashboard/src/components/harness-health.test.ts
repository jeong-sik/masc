import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { KpiStrip } from './kpi-strip'
import { KpiCell } from './kpi-cell'

function sampleResponse() {
  return {
    generated_at: 1711440000,
    scope_note: 'Autoresearch는 generator loop, Harness는 safety rail을 설명합니다.',
    overview: {
      evaluator_status: 'warning',
      pre_compact_status: 'healthy',
      handoff_status: 'healthy',
      last_signal_at: 1711440300,
      evaluator_last_event_at: 1711440300,
      pre_compact_last_event_at: 1711440000,
      handoff_last_event_at: 1711430000,
      fallback_ratio: 0.83,
      latest_pre_compact_ratio: 0.91,
      latest_handoff_generation: 27,
    },
    calibration: {
      total_verdicts: 12,
      approve_count: 9,
      reject_count: 3,
      gate_distribution: { fallback: 7, judge: 5 },
      labeled_count: 4,
      false_positive_count: 1,
      false_negative_count: 0,
      agreement_rate: 0.75,
      fallback_count: 10,
      recent_fallback_reasons: ['judge timeout'],
    },
    recent_verdicts: [
      {
        timestamp: 1711440000,
        task_id: 'task-1',
        task_title: 'Review task notes',
        agent_name: 'judge',
        gate: 'llm',
        verdict: 'approve',
        evaluator_cascade: 'verifier',
        fallback_reason: null,
      },
    ],
    pre_compact: {
      description: 'Pre-compaction signal',
      status: 'healthy',
      last_event_at: 1711440000,
      empty_reason: null,
      total_recent: 1,
      recent_events: [
        {
          timestamp: 1711440000,
          keeper_name: 'keeper-a',
          context_ratio: 0.91,
          message_count: 88,
          token_count: 32000,
          strategies: ['PruneToolOutputs'],
          model_family: 'verifier',
          trigger: 'ratio(0.91>=0.85)',
        },
      ],
    },
    recent_handoffs: {
      description: 'Keeper checkpoint rollovers sourced from keeper metrics snapshots.',
      status: 'healthy',
      last_event_at: 1711430000,
      empty_reason: null,
      total_recent: 1,
      recent_events: [
        {
          timestamp: 1711430000,
          keeper_name: 'keeper-a',
          trace_id: 'trace-abc123',
          generation: 5,
          next_generation: 6,
          prev_trace_id: 'trace-prev',
          new_trace_id: 'trace-new',
          to_model: null,
        },
      ],
    },
  }
}

async function flushUi(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

async function loadComponentWithApi(api: {
  get: (path: string) => Promise<unknown>
  lastEvent: { value: unknown; subscribe?: (callback: (event: unknown) => void) => () => void }
  navigate?: (tab: string, params?: Record<string, string>) => void
}) {
  vi.resetModules()
  const lastEvent =
    typeof api.lastEvent.subscribe === 'function'
      ? api.lastEvent
      : {
          value: api.lastEvent.value,
          subscribe: () => () => {},
        }
  vi.doMock('../api/core', () => ({
    get: api.get,
  }))
  vi.doMock('../sse', () => ({
    lastEvent,
  }))
  vi.doMock('../router', () => ({
    navigate: api.navigate ?? vi.fn(),
  }))
  // Synchronous Preact shim — KpiStripIsland mounts its Solid subtree
  // inside useEffect, so cell text would only appear after a flush. The
  // existing assertions on '9세대' etc. fire immediately. Production
  // ships the real island; this shim is test-config-only. Real island
  // integration tests live in kpi-strip-island.solid.test.ts.
  vi.doMock('./kpi-strip-island', () => ({
    KpiStripIsland: (props: {
      ariaLabel: string
      variant?: 'standard' | 'compact' | 'stacked'
      cols?: number
      cells: ReadonlyArray<Record<string, unknown>>
    }) => html`
      <${KpiStrip}
        ariaLabel=${props.ariaLabel}
        variant=${props.variant}
        cols=${props.cols}
      >
        ${props.cells.map((cell) => html`<${KpiCell} ...${cell} />`)}
      <//>
    `,
  }))
  vi.doMock('./common/mermaid-graph', () => ({
    MermaidGraph: ({ source, fallbackText }: { source: string; fallbackText?: string }) => html`
      <pre data-testid="mermaid-source">${source}</pre>
      ${fallbackText ? html`<div data-testid="mermaid-fallback">${fallbackText}</div>` : null}
    `,
  }))
  const module = await import('./harness-health')
  module.resetHarnessHealthState()
  return module
}

function mermaidSource(container: HTMLDivElement): string {
  return container.querySelector('[data-testid="mermaid-source"]')?.textContent ?? ''
}

describe('HarnessHealth', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(async () => {
    const { resetHarnessHealthState } = await import('./harness-health')
    resetHarnessHealthState()
    render(null, container)
    container.remove()
    vi.useRealTimers()
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('../api/core')
    vi.doUnmock('../sse')
    vi.doUnmock('../router')
    vi.doUnmock('./common/mermaid-graph')
  })

  it('renders the live harness hierarchy with shared theme tokens', async () => {
    const get = vi.fn<(path: string) => Promise<unknown>>()
      .mockResolvedValue(sampleResponse())

    const { HarnessHealth } = await loadComponentWithApi({
      get,
      lastEvent: { value: null },
    })

    render(html`<${HarnessHealth} />`, container)
    await flushUi()

    expect(get).toHaveBeenCalledWith('/api/v1/dashboard/harness-health')
    expect(container.textContent).toContain('안전 감시')
    expect(container.textContent).toContain('감시 흐름도')
    expect(container.textContent).toContain('keeper 장기 실행 중 평가/압축/교체가 정상인지 감시합니다')
    expect(container.textContent).toContain('평가 모델 건강도')
    expect(container.textContent).toContain('컨텍스트 압축 압력')
    expect(container.textContent).toContain('keeper 세대 교체')
    expect(container.textContent).toContain('오토리서치 열기')
    expect(container.textContent).toContain('대체 처리율')
    expect(container.textContent).toContain('judge timeout')
    expect(mermaidSource(container)).toContain('flowchart LR')
    expect(mermaidSource(container)).toContain('판정 기록')
    expect(mermaidSource(container)).toContain('debounced reload')

    const markup = container.innerHTML
    // Shared theme tokens reach the markup. KpiCell (post-StatCard swap)
    // emits `--color-fg-primary` via inline style; the rest of the
    // hierarchy still wears Tailwind theme-token utilities.
    expect(markup).toContain('var(--color-fg-primary)')
    expect(markup).toContain('var(--color-')
    expect(markup).not.toContain('bg-slate-800')
    expect(markup).not.toContain('bg-slate-700')
    expect(markup).not.toContain('text-slate-400')
    expect(markup).not.toContain('text-slate-500')
  })

  it('debounces a full reload after a harness SSE event', async () => {
    const get = vi.fn<(path: string) => Promise<unknown>>()
      .mockResolvedValue(sampleResponse())
    const lastEvent = signal<unknown>(null)

    const { HarnessHealth } = await loadComponentWithApi({
      get,
      lastEvent,
    })

    render(html`<${HarnessHealth} />`, container)
    await flushUi()
    expect(get).toHaveBeenCalledTimes(1)

    lastEvent.value = {
      type: 'oas:masc:harness:verdict_recorded',
      payload: {
        timestamp: 1711440600,
        task_id: 'task-2',
        task_title: 'transition-done',
        agent_name: 'codex',
        gate: 'fallback',
        verdict: 'reject:vague notes',
        evaluator_cascade: 'cross_verifier',
        fallback_reason: 'judge timeout',
      },
    }
    await flushUi()

    expect(container.textContent).toContain('transition-done')
    expect(get).toHaveBeenCalledTimes(1)

    await new Promise(resolve => setTimeout(resolve, 1000))
    await flushUi()

    expect(get).toHaveBeenCalledTimes(2)
  })

  it('derives a status-aware mermaid graph from harness data', async () => {
    const module = await loadComponentWithApi({
      get: vi.fn().mockResolvedValue(sampleResponse()),
      lastEvent: { value: null },
    })

    const source = module.buildHarnessFlowMermaid(sampleResponse() as never)

    expect(source).toContain('class evaluator warningRail;')
    expect(source).toContain('class preCompact healthyRail;')
    expect(source).toContain('class handoff healthyRail;')
    expect(source).toContain('class evaluator activeRail;')
    expect(source).toContain('교체 신호')
    expect(source).toContain('/api/v1/dashboard/harness-health')
    // Mermaid classDef parser cannot lex CSS var(--token) — colors must stay as hex literals.
    expect(source).not.toMatch(/classDef[^\n]*var\(/)
  })

  it('updates the handoff rail immediately on keeper_handoff SSE events', async () => {
    const get = vi.fn<(path: string) => Promise<unknown>>()
      .mockResolvedValue(sampleResponse())
    const lastEvent = signal<unknown>(null)

    const { HarnessHealth } = await loadComponentWithApi({
      get,
      lastEvent,
    })

    render(html`<${HarnessHealth} />`, container)
    await flushUi()
    expect(container.textContent).toContain('keeper-a')

    lastEvent.value = {
      type: 'oas:masc:harness:handoff',
      payload: {
        timestamp: 1711440900,
        keeper_name: 'keeper-b',
        trace_id: 'trace-b',
        generation: 8,
        next_generation: 9,
        to_model: 'glm-5',
      },
    }
    await flushUi()

    expect(container.textContent).toContain('keeper-b')
    expect(container.textContent).toContain('9세대')
    expect(mermaidSource(container)).toContain('class handoff activeRail;')

    await new Promise(resolve => setTimeout(resolve, 1000))
    await flushUi()

    expect(get).toHaveBeenCalledTimes(2)
  })
})
