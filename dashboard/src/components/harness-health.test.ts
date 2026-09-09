import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { waitFor } from '@testing-library/preact'

const RETIRED_BRIGHT_GREEN = '#4ade80'

function sampleResponse() {
  return {
    generated_at: 1711440000,
    scope_note: 'Harness health explains safety rails and calibration loops.',
    overview: {
      evaluator_status: 'warning',
      last_signal_at: 1711440300,
      evaluator_last_event_at: 1711440300,
      fallback_ratio: 0.83,
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
        evaluator_runtime: 'verifier',
        fallback_reason: null,
      },
    ],
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
  vi.doMock('./common/mermaid-graph', () => ({
    MermaidGraph: ({ source, fallbackText }: { source: string; fallbackText?: string }) => html`
      <pre data-testid="mermaid-source">${source}</pre>
      ${fallbackText ? html`<div data-testid="mermaid-fallback">${fallbackText}</div>` : null}
    `,
  }))
  const module = await import('./harness-health')
  const { resetHarnessHealthState } = await import('./harness-health-state')
  resetHarnessHealthState()
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
    const { resetHarnessHealthState } = await import('./harness-health-state')
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

    expect(container.querySelector('.v2-lab-surface')).not.toBeNull()
    expect(container.querySelector('.v2-lab-panel')).not.toBeNull()
    expect(get).toHaveBeenCalledWith('/api/v1/dashboard/harness-health')
    expect(container.textContent).toContain('안전 감시')
    expect(container.textContent).toContain('감시 흐름도')
    expect(container.textContent).toContain('keeper 장기 실행 중 평가 판정이 정상인지 감시합니다')
    expect(container.textContent).toContain('평가 모델 건강도')
    expect(container.textContent).toContain('대체 처리율')
    expect(container.textContent).toContain('judge timeout')
    expect(mermaidSource(container)).toContain('flowchart LR')
    expect(mermaidSource(container)).toContain('판정 기록')
    expect(mermaidSource(container)).toContain('debounced reload')

    // Dark-fantasy palette regression: mermaid classDefs (which cannot use
    // CSS vars) carry the _ds Dark-Fantasy literals, not the retired
    // navy/cyan/green set.
    expect(mermaidSource(container)).toContain('#5a7a3a') // healthy stroke — status-ok (bile)
    expect(mermaidSource(container)).toContain('#c4a265') // hub / active — brass accent
    expect(mermaidSource(container)).not.toContain('#38bdf8') // retired cyan
    expect(mermaidSource(container)).not.toContain('#0f172a') // retired navy
    expect(mermaidSource(container)).not.toContain(RETIRED_BRIGHT_GREEN)

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
      type: 'agent_core:masc:harness:verdict_recorded',
      payload: {
        timestamp: 1711440600,
        task_id: 'task-2',
        task_title: 'transition-done',
        agent_name: 'codex',
        gate: 'fallback',
        verdict: 'reject:vague notes',
        evaluator_runtime: 'judge-runtime',
        generator_runtime: 'generator_runtime',
        cross_runtime: true,
        fallback_reason: 'judge timeout',
      },
    }
    await flushUi()

    expect(container.textContent).toContain('transition-done')
    expect(get).toHaveBeenCalledTimes(1)

    // The reload is debounced 700ms (HARNESS_RELOAD_DEBOUNCE_MS). Sleeping
    // past it and then asserting bets the timer is never late; under a
    // parallel suite run it is. Waiting for the call returns as soon as it
    // lands and tolerates a timer that fires behind schedule.
    await waitFor(() => expect(get).toHaveBeenCalledTimes(2), { timeout: 5000 })
  })

  it('derives a status-aware mermaid graph from harness data', async () => {
    const module = await loadComponentWithApi({
      get: vi.fn().mockResolvedValue(sampleResponse()),
      lastEvent: { value: null },
    })

    const source = module.buildHarnessFlowMermaid(sampleResponse() as never)

    expect(source).toContain('class evaluator warningRail;')
    expect(source).toContain('class evaluator activeRail;')
    expect(source).toContain('/api/v1/dashboard/harness-health')
    // Mermaid classDef parser cannot lex CSS var(--token) — colors must stay as hex literals.
    expect(source).not.toMatch(/classDef[^\n]*var\(/)
  })

})
