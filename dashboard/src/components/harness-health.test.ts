import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

async function flushUi(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

async function loadComponentWithApi(api: {
  get: (path: string) => Promise<unknown>
  lastEvent: { value: unknown }
}) {
  vi.resetModules()
  vi.doMock('../api/core', () => ({
    get: api.get,
  }))
  vi.doMock('../sse', () => ({
    lastEvent: api.lastEvent,
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
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('../api/core')
    vi.doUnmock('../sse')
  })

  it('uses shared theme tokens instead of hardcoded slate palette classes', async () => {
    const get = vi.fn<(path: string) => Promise<unknown>>()
      .mockResolvedValue({
        generated_at: 1711440000,
        scope_note: 'Autoresearch는 generator loop, Harness는 safety rail을 설명합니다.',
        calibration: {
          total_verdicts: 12,
          approve_count: 9,
          reject_count: 3,
          gate_distribution: { fallback: 7, judge: 5 },
          labeled_count: 4,
          false_positive_count: 1,
          false_negative_count: 0,
          agreement_rate: 0.75,
          fallback_count: 2,
          recent_fallback_reasons: [],
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
      })

    const { HarnessHealth } = await loadComponentWithApi({
      get,
      lastEvent: {
        value: {
          type: 'oas:masc:harness:verdict_recorded',
          payload: {
            gate: 'judge',
            verdict: 'approve',
          },
        },
      },
    })

    render(html`<${HarnessHealth} />`, container)
    await flushUi()

    expect(get).toHaveBeenCalledWith('/api/v1/dashboard/harness-health')
    expect(container.textContent).toContain('Safety Harness')
    expect(container.textContent).toContain('Evaluator Calibration')
    expect(container.textContent).toContain('Pre-Compaction Rail')
    expect(container.textContent).toContain('DNA Quality Rail')
    expect(container.textContent).toContain('Autoresearch는 generator loop')

    const markup = container.innerHTML
    expect(markup).toContain('text-[var(--accent)]')
    expect(markup).toContain('bg-[var(--ok)]')
    expect(markup).not.toContain('bg-slate-800')
    expect(markup).not.toContain('bg-slate-700')
    expect(markup).not.toContain('text-slate-400')
    expect(markup).not.toContain('text-slate-500')
    expect(markup).not.toContain('text-amber-400')
    expect(markup).not.toContain('bg-green-500')
    expect(markup).not.toContain('bg-red-500')
  })
})
