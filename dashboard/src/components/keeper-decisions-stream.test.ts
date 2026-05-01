// @vitest-environment happy-dom
import { h, render } from 'preact'
import { describe, expect, it } from 'vitest'
import type { KeeperDecision } from '../api/dashboard'
import {
  decisionOutcomeTone,
  formatDecisionTime,
  KeeperDecisionsTable,
  summarizeDecisionEvents,
} from './keeper-decisions-stream'

function makeDecision(overrides: Partial<KeeperDecision> = {}): KeeperDecision {
  return {
    ts_unix: 1_714_000_000,
    keeper_name: 'sangsu',
    event_type: 'turn',
    outcome: 'success',
    model_used: 'gpt-test',
    latency_ms: 1234,
    cost_usd: 0.0123,
    input_tokens: 100,
    output_tokens: 50,
    stop_reason: null,
    error_category: null,
    tool: null,
    duration_ms: null,
    match_count: null,
    ...overrides,
  }
}

describe('keeper decision helpers', () => {
  it('classifies outcome tones', () => {
    expect(decisionOutcomeTone('success')).toContain('ok')
    expect(decisionOutcomeTone('error')).toContain('err')
    expect(decisionOutcomeTone(null)).toContain('muted')
  })

  it('summarizes success, error, and tool-linked rows', () => {
    expect(summarizeDecisionEvents([
      makeDecision(),
      makeDecision({ outcome: 'error', tool: 'keeper_shell' }),
      makeDecision({ outcome: null }),
    ])).toEqual({
      total: 3,
      success: 1,
      error: 1,
      tool: 1,
    })
  })

  it('formats missing timestamps as a table placeholder', () => {
    expect(formatDecisionTime(null)).toBe('-')
  })
})

describe('KeeperDecisionsTable', () => {
  it('renders decision rows and aggregate metrics', () => {
    const container = document.createElement('div')
    render(h(KeeperDecisionsTable, {
      events: [
        makeDecision(),
        makeDecision({
          keeper_name: 'janitor',
          event_type: 'tool_call',
          outcome: 'error',
          model_used: null,
          latency_ms: null,
          cost_usd: null,
          tool: 'keeper_shell',
        }),
      ],
      limit: 200,
    }), container)

    expect(container.textContent).toContain('keeper decisions')
    expect(container.textContent).toContain('2 events')
    expect(container.textContent).toContain('sangsu')
    expect(container.textContent).toContain('janitor')
    expect(container.textContent).toContain('tool_call')
    expect(container.textContent).toContain('keeper_shell')
    render(null, container)
  })

  it('renders the empty state without a table', () => {
    const container = document.createElement('div')
    render(h(KeeperDecisionsTable, { events: [], limit: 200 }), container)

    expect(container.textContent).toContain('No keeper decision events')
    expect(container.querySelector('table')).toBeNull()
    render(null, container)
  })
})
