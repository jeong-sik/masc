// @ts-nocheck
import { describe, expect, it } from 'vitest'
import {
  classifyFusionJudgeShape,
  extractFusionEvidence,
  firstNumber,
  firstString,
  normalizeFusionJudge,
  normalizeFusionJudgeNodes,
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
    expect(
      normalizeFusionPanelReason(
        'gpt-5',
        'Fusion_types.Empty_response "empty response (stop_reason=max_tokens)"',
      ),
    ).toBe('empty response (stop_reason=max_tokens)')
  })

  it('normalizes Invalid_max_output_tokens without provider attribution', () => {
    expect(
      normalizeFusionPanelReason('gpt-5', '( Fusion_types.Invalid_max_output_tokens 0 )'),
    ).toBe('invalid max_output_tokens 0')
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

  it('carries the RFC-0284 judges observation array (judge-of-judges)', () => {
    const evidence = extractFusionEvidence({
      source: 'fusion',
      run_id: 'fus-joj',
      panel: [{ model: 'gpt-5', status: 'answered' }],
      judge: { status: 'synthesized' },
      judges: [
        { role: 'first', identity: 'gpt-5', input_tokens: 10, output_tokens: 20 },
        { role: 'first', identity: 'claude', status: 'failed', error: 'timeout' },
        { role: 'meta', identity: 'meta' },
      ],
    })
    expect(evidence?.judges).toHaveLength(3)
    expect(evidence?.judges[0]).toMatchObject({ role: 'first', identity: 'gpt-5', failed: false })
    // toMatchObject ignores extra keys, so pin that a success node carries no error
    expect(evidence?.judges[0]?.error).toBeUndefined()
    expect(evidence?.judges[1]).toMatchObject({ role: 'first', failed: true, error: 'timeout' })
    expect(evidence?.judges[2]?.role).toBe('meta')
  })

  it('defaults judges to [] when the meta predates the array', () => {
    const evidence = extractFusionEvidence({
      source: 'fusion',
      panel: [{ model: 'gpt-5', status: 'answered' }],
      judge: { status: 'synthesized' },
    })
    expect(evidence?.judges).toEqual([])
  })
})

describe('normalizeFusionJudgeNodes', () => {
  it('returns [] for a non-array', () => {
    expect(normalizeFusionJudgeNodes(undefined)).toEqual([])
    expect(normalizeFusionJudgeNodes({})).toEqual([])
    expect(normalizeFusionJudgeNodes(null)).toEqual([])
  })

  it('parses Synthesized and Judge_failed nodes (status:"failed" marks failure)', () => {
    const nodes = normalizeFusionJudgeNodes([
      { role: 'first', identity: 'gpt-4o', input_tokens: 100, output_tokens: 10 },
      { role: 'first', identity: 'gemini', status: 'failed', error: 'timeout', input_tokens: 5, output_tokens: 0 },
      { role: 'meta', identity: 'o1', input_tokens: 2000, output_tokens: 418 },
    ])
    expect(nodes).toHaveLength(3)
    expect(nodes[0]).toMatchObject({
      role: 'first',
      identity: 'gpt-4o',
      failed: false,
      error: undefined,
      inputTokens: 100,
      outputTokens: 10,
    })
    expect(nodes[1]).toMatchObject({
      role: 'first',
      identity: 'gemini',
      failed: true,
      error: 'timeout',
      inputTokens: 5,
      outputTokens: 0,
    })
    expect(nodes[2]).toMatchObject({
      role: 'meta',
      identity: 'o1',
      failed: false,
      error: undefined,
      inputTokens: 2000,
      outputTokens: 418,
    })
  })

  it('drops non-record elements and defaults a missing role/identity', () => {
    const nodes = normalizeFusionJudgeNodes([null, 'x', { input_tokens: 1 }])
    expect(nodes).toHaveLength(1)
    expect(nodes[0].role).toBe('judge')
    expect(nodes[0].identity).toBe('judge-3')
  })

  it('carries per-node decision + resolved-answer summary for a synthesized node, none for a failed node', () => {
    const nodes = normalizeFusionJudgeNodes([
      {
        role: 'first',
        identity: 'skeptic',
        decision: 'recommend — patch first',
        resolved_answer: 'Patch the compact isolation first.',
        input_tokens: 100,
        output_tokens: 10,
      },
      { role: 'first', identity: 'domain', status: 'failed', error: 'timeout' },
    ])
    expect(nodes[0].decision).toBe('recommend — patch first')
    expect(nodes[0].summary).toBe('Patch the compact isolation first.')
    // a failed node carries neither verdict nor summary (Judge_failed emits neither)
    expect(nodes[1].decision).toBeUndefined()
    expect(nodes[1].summary).toBeUndefined()
  })

  it('falls back to synthesis when a synthesized node has no resolved_answer', () => {
    const [node] = normalizeFusionJudgeNodes([
      { role: 'first', identity: 'lit', decision: 'insufficient — missing: data', synthesis: '**Decision**: insufficient' },
    ])
    expect(node.summary).toBe('**Decision**: insufficient')
  })

  it('extracts failure_code / elapsed_s / timed_out from a Judge_failed node', () => {
    const [node] = normalizeFusionJudgeNodes([
      {
        role: 'meta',
        identity: 'o1',
        status: 'failed',
        error: 'judge budget exceeded',
        failure_code: 'budget_exceeded',
        elapsed_s: 12.5,
        timed_out: true,
        input_tokens: 800,
        output_tokens: 0,
      },
    ])
    expect(node).toMatchObject({
      role: 'meta',
      failed: true,
      error: 'judge budget exceeded',
      failureCode: 'budget_exceeded',
      elapsedS: 12.5,
      timedOut: true,
    })
  })

  it('leaves failure attribution undefined on a successful node', () => {
    const [node] = normalizeFusionJudgeNodes([
      { role: 'first', identity: 'gpt-4o', input_tokens: 100, output_tokens: 10 },
    ])
    expect(node.failureCode).toBeUndefined()
    expect(node.elapsedS).toBeUndefined()
    expect(node.timedOut).toBeUndefined()
  })
})

describe('classifyFusionJudgeShape', () => {
  // role values match fusion_sink.ml judge_role_fields: single | refine | first | meta.
  const node = role => ({ role, identity: 'm', failed: false })

  it('a lone single node -> single', () => {
    expect(classifyFusionJudgeShape([node('single')])).toBe('single')
  })

  it('Single + Refine_pass (refine/conditional 2nd judge) -> refine', () => {
    expect(classifyFusionJudgeShape([node('single'), node('refine')])).toBe('refine')
  })

  it('N first-judges + a meta -> judge-of-judges', () => {
    expect(classifyFusionJudgeShape([node('first'), node('first'), node('meta')])).toBe(
      'judge-of-judges',
    )
  })

  it('all-fail JoJ (first-judges, no meta) -> judge-of-judges, not refine', () => {
    // `first` is JoJ-exclusive on the backend, so two first-judges with no meta
    // (every first judge failed → meta never ran) must not be read as refine.
    expect(classifyFusionJudgeShape([node('first'), node('first')])).toBe('judge-of-judges')
    expect(classifyFusionJudgeShape([node('first'), node('first'), node('first')])).toBe(
      'judge-of-judges',
    )
  })

  it('an unanticipated shape -> custom (still renders structurally)', () => {
    expect(classifyFusionJudgeShape([])).toBe('custom')
    expect(classifyFusionJudgeShape([node('single'), node('single')])).toBe('custom')
  })
})
