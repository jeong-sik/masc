import { describe, expect, it } from 'vitest'

import {
  AutoresearchSchemaDriftError,
  parseAutoresearchLoopActionResponse,
  parseAutoresearchLoopDetail,
  parseAutoresearchLoopsResponse,
} from './autoresearch'

function validSummary(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    loop_id: 'loop-1',
    author: null,
    goal: 'maximize coverage',
    metric_fn: 'coverage.sh',
    model_model: 'claude-opus-4-7',
    target_file: 'lib/foo.ml',
    status: 'running',
    current_cycle: 3,
    max_cycles: 20,
    baseline: 0.5,
    best_score: 0.82,
    best_cycle: 2,
    total_keeps: 2,
    total_discards: 1,
    elapsed_s: 135.4,
    updated_at: 1_712_000_000,
    live: true,
    workdir: '/tmp/wd',
    source_workdir: '/tmp/src',
    program_note: null,
    warnings: [],
    insights: ['insight-1'],
    recent_cycles: [],
    error: null,
    session_id: 'sess-1',
    operation_id: null,
    linked_at: null,
    queued_hypothesis: null,
    ...overrides,
  }
}

describe('parseAutoresearchLoopsResponse', () => {
  it('accepts a well-formed response with zero loops', () => {
    const out = parseAutoresearchLoopsResponse({ loops: [], total: 0, offset: 0, limit: 100 })
    expect(out.total).toBe(0)
    expect(out.loops).toHaveLength(0)
  })

  it('accepts a populated list and infers summary types', () => {
    const out = parseAutoresearchLoopsResponse({
      loops: [validSummary(), validSummary({ loop_id: 'loop-2', status: 'completed' })],
      total: 2,
      offset: 0, limit: 100
    })
    expect(out.loops).toHaveLength(2)
    expect(out.loops[1]!.status).toBe('completed')
  })

  it('falls back to status=error when backend ships an unknown lifecycle value', () => {
    // Hard-rejection would brick the operator view during a backend-ahead
    // deploy window; unknown values render as "error" instead.
    const out = parseAutoresearchLoopsResponse({
      loops: [validSummary({ status: 'defragmenting' })],
      total: 1,
      offset: 0, limit: 100
    })
    expect(out.loops[0]!.status).toBe('error')
  })

  it('throws AutoresearchSchemaDriftError when a required field is missing', () => {
    const bad = { loops: [validSummary({ loop_id: undefined })], total: 1, offset: 0, limit: 100 }
    expect(() => parseAutoresearchLoopsResponse(bad)).toThrow(AutoresearchSchemaDriftError)
  })

  it('throws when the response is a primitive', () => {
    expect(() => parseAutoresearchLoopsResponse('not an object')).toThrow(
      AutoresearchSchemaDriftError,
    )
  })
})

describe('parseAutoresearchLoopDetail', () => {
  it('accepts detail payload with history', () => {
    const detail = {
      ...validSummary(),
      history: [
        {
          cycle: 1,
          hypothesis: 'try smaller batch',
          score_before: 0.5,
          score_after: 0.6,
          delta: 0.1,
          decision: 'keep',
          commit_hash: 'abc123',
          elapsed_ms: 4200,
          model_used: 'claude-opus-4-7',
          timestamp: 1_712_000_100,
        },
      ],
      history_count: 1,
    }
    const out = parseAutoresearchLoopDetail(detail)
    expect(out.history).toHaveLength(1)
    expect(out.history[0]!.decision).toBe('keep')
  })

  it('throws when history is missing', () => {
    expect(() => parseAutoresearchLoopDetail(validSummary())).toThrow(
      AutoresearchSchemaDriftError,
    )
  })
})

describe('parseAutoresearchLoopActionResponse', () => {
  it('accepts ok with action and loop_id', () => {
    const out = parseAutoresearchLoopActionResponse({
      ok: true,
      action: 'retry',
      loop_id: 'loop-1',
    })
    expect(out.ok).toBe(true)
    expect(out.action).toBe('retry')
  })

  it('accepts a minimal response with just ok', () => {
    const out = parseAutoresearchLoopActionResponse({ ok: false, error: 'no such loop' })
    expect(out.ok).toBe(false)
    expect(out.error).toBe('no such loop')
  })

  it('throws when the shape is not an object', () => {
    expect(() => parseAutoresearchLoopActionResponse(null)).toThrow(
      AutoresearchSchemaDriftError,
    )
  })
})
