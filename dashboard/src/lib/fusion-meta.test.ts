// @ts-nocheck
import { describe, expect, it } from 'vitest'
import {
  extractFusionEvidence,
  firstNumber,
  firstString,
  normalizeFusionJudge,
  normalizeFusionPanel,
  normalizeFusionPanelReason,
  normalizeFusionUsage,
} from './fusion-meta'

describe('normalizeFusionPanelReason', () => {
  it('returns undefined for empty reason', () => {
    expect(normalizeFusionPanelReason('gpt-5', undefined)).toBeUndefined()
    expect(normalizeFusionPanelReason('gpt-5', '')).toBeUndefined()
  })

  it('decodes OCaml Provider_error literals', () => {
    expect(
      normalizeFusionPanelReason('gpt-5', 'Fusion_types.Provider_error "quota exceeded"'),
    ).toBe('quota exceeded')
  })

  it('re-attributions Provider unknown errors to the real model id', () => {
    expect(
      normalizeFusionPanelReason(
        'gpt-5',
        "Fusion_types.Provider_error \"Provider 'unknown': rate limit\"",
      ),
    ).toBe("Provider 'gpt-5': rate limit")
  })

  it('normalizes Timeout and Empty_response constructors', () => {
    expect(normalizeFusionPanelReason('gpt-5', 'Fusion_types.Timeout')).toBe('timeout')
    expect(normalizeFusionPanelReason('gpt-5', '( Fusion_types.Empty_response )')).toBe(
      'empty response',
    )
  })

  it('passes through plain reasons', () => {
    expect(normalizeFusionPanelReason('gpt-5', 'context too long')).toBe('context too long')
  })
})

describe('firstString', () => {
  it('returns the first non-empty string by key order', () => {
    expect(firstString({ a: '', b: 'win', c: 'also' }, ['a', 'b', 'c'])).toBe('win')
  })

  it('skips non-strings and whitespace', () => {
    expect(firstString({ a: 123, b: '  ', c: 'ok' }, ['a', 'b', 'c'])).toBe('ok')
  })

  it('returns null when nothing matches', () => {
    expect(firstString({}, ['a'])).toBeNull()
  })
})

describe('firstNumber', () => {
  it('returns the first finite number by key order', () => {
    expect(firstNumber({ a: NaN, b: 42, c: 99 }, ['a', 'b', 'c'])).toBe(42)
  })

  it('parses numeric strings', () => {
    expect(firstNumber({ a: '123', b: 456 }, ['a', 'b'])).toBe(123)
  })

  it('returns null when nothing matches', () => {
    expect(firstNumber({ a: 'not-a-number' }, ['a'])).toBeNull()
  })
})

describe('normalizeFusionPanel', () => {
  it('returns an empty array for non-array input', () => {
    expect(normalizeFusionPanel(null)).toEqual([])
    expect(normalizeFusionPanel({})).toEqual([])
  })

  it('normalizes a complete panel entry', () => {
    const panel = normalizeFusionPanel([
      {
        model: 'gpt-5',
        status: 'answered',
        answer: 'canary',
        reason_detail: 'Fusion_types.Provider_error "quota"',
        reason_code: 'provider_error',
        input_tokens: 100,
        output_tokens: '200',
      },
    ])
    expect(panel).toHaveLength(1)
    expect(panel[0]).toMatchObject({
      model: 'gpt-5',
      status: 'answered',
      answer: 'canary',
      reason: 'quota',
      reasonCode: 'provider_error',
      inputTokens: 100,
      outputTokens: 200,
    })
  })

  it('falls back to model aliases and summed usage', () => {
    const panel = normalizeFusionPanel([
      { name: 'claude', status: '', usage: { input_tokens: '10', output_tokens: 20 } },
    ])
    expect(panel[0].model).toBe('claude')
    expect(panel[0].status).toBe('unknown')
    expect(panel[0].inputTokens).toBe(10)
    expect(panel[0].outputTokens).toBe(20)
  })

  it('drops non-record entries and assigns a fallback name when model is missing', () => {
    const panel = normalizeFusionPanel(['not-a-record', {}])
    expect(panel).toHaveLength(1)
    expect(panel[0].model).toBe('panel-2')
  })
})

describe('normalizeFusionJudge', () => {
  it('returns null for non-record input', () => {
    expect(normalizeFusionJudge(null)).toBeNull()
    expect(normalizeFusionJudge('synthesized')).toBeNull()
  })

  it('normalizes judge with aliases', () => {
    const judge = normalizeFusionJudge({
      status: 'synthesized',
      verdict: 'answer',
      summary: 'ship it',
      resolvedAnswer: 'canary',
      error: 'none',
    })
    expect(judge).toMatchObject({
      status: 'synthesized',
      decision: 'answer',
      synthesis: 'ship it',
      resolvedAnswer: 'canary',
      error: 'none',
    })
  })
})

describe('normalizeFusionUsage', () => {
  it('prefers observed_usage over summed panel tokens', () => {
    const usage = normalizeFusionUsage(
      { observed_usage: { input_tokens: 1000, output_tokens: 2000 } },
      [{ inputTokens: 1, outputTokens: 2 }],
    )
    expect(usage).toEqual({ inputTokens: 1000, outputTokens: 2000 })
  })

  it('falls back to meta-level tokens', () => {
    const usage = normalizeFusionUsage({ input_tokens: '500', output_tokens: '600' })
    expect(usage).toEqual({ inputTokens: 500, outputTokens: 600 })
  })

  it('sums panel tokens when no top-level value is present', () => {
    const usage = normalizeFusionUsage(
      {},
      [{ inputTokens: 10, outputTokens: 20 }, { inputTokens: 5, outputTokens: 5 }],
    )
    expect(usage).toEqual({ inputTokens: 15, outputTokens: 25 })
  })
})

describe('extractFusionEvidence', () => {
  it('returns null for non-record meta', () => {
    expect(extractFusionEvidence(null)).toBeNull()
    expect(extractFusionEvidence('fusion')).toBeNull()
  })

  it('extracts evidence from explicit source tag', () => {
    const evidence = extractFusionEvidence({
      source: 'fusion',
      run_id: 'fus-1',
      question: 'q?',
      panel: [{ model: 'gpt-5', status: 'answered' }],
      judge: { status: 'synthesized' },
    })
    expect(evidence).toMatchObject({
      source: 'fusion',
      runId: 'fus-1',
      question: 'q?',
      panel: [{ model: 'gpt-5', status: 'answered' }],
      judge: { status: 'synthesized' },
    })
  })

  it('unwraps nested fusion_deliberation', () => {
    const evidence = extractFusionEvidence({
      fusion_deliberation: {
        run_id: 'fus-legacy',
        panel: [{ model: 'gpt-5', status: 'answered' }],
        judge: { status: 'synthesized' },
      },
    })
    expect(evidence?.runId).toBe('fus-legacy')
    expect(evidence?.panel).toHaveLength(1)
  })

  it('falls back to panel + judge heuristic when source is missing', () => {
    const evidence = extractFusionEvidence({
      panel: [{ model: 'gpt-5', status: 'answered' }],
      judge: { status: 'synthesized' },
    })
    expect(evidence).not.toBeNull()
    expect(evidence?.source).toBe('fusion')
  })
})
