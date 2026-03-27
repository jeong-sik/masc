import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

function sampleResponse() {
  return {
    generated_at: 1711440000,
    scope_note: 'Autoresearch는 generator loop, Harness는 safety rail을 설명합니다.',
    overview: {
      evaluator_status: 'warning',
      pre_compact_status: 'healthy',
      dna_status: 'stale',
      last_signal_at: 1711440300,
      evaluator_last_event_at: 1711440300,
      pre_compact_last_event_at: 1711440000,
      dna_last_event_at: 1711430000,
      fallback_ratio: 0.83,
      latest_pre_compact_ratio: 0.91,
      latest_dna_score: 0.82,
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
    dna_quality: {
      description: 'DNA signal',
      status: 'stale',
      last_event_at: 1711430000,
      empty_reason: null,
      total_recent: 1,
      recent_events: [
        {
          timestamp: 1711440000,
          keeper_name: 'keeper-a',
          score: 0.82,
          dimensions: {
            has_goal_anchor: true,
            has_task_anchor: true,
            has_recent_context: true,
            truncation_artifacts: 0,
            content_length: 420,
          },
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
  lastEvent: { value: unknown }
  navigate?: (tab: string, params?: Record<string, string>) => void
}) {
  vi.resetModules()
  vi.doMock('../api/core', () => ({
    get: api.get,
  }))
  vi.doMock('../sse', () => ({
    lastEvent: api.lastEvent,
  }))
  vi.doMock('../router', () => ({
    navigate: api.navigate ?? vi.fn(),
  }))
  return import('./harness-health')
}

describe('HarnessHealth', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.useRealTimers()
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('../api/core')
    vi.doUnmock('../sse')
    vi.doUnmock('../router')
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
    expect(container.textContent).toContain('Safety Harness')
    expect(container.textContent).toContain('Can I Trust The Experiment Machinery?')
    expect(container.textContent).toContain('Judge of the Judge')
    expect(container.textContent).toContain('Continuity Pressure')
    expect(container.textContent).toContain('Continuity DNA')
    expect(container.textContent).toContain('오토리서치 열기')
    expect(container.textContent).toContain('Fallback 비율')
    expect(container.textContent).toContain('judge timeout')

    const markup = container.innerHTML
    expect(markup).toContain('text-[var(--accent)]')
    expect(markup).toContain('bg-[var(--ok-12)]')
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
})
