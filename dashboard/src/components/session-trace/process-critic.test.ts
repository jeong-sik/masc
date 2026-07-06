import { describe, expect, it } from 'vitest'
import { evaluateProcessTrace, type ProcessCriticFinding } from './process-critic'
import type { TraceSummary, UnifiedTraceEvent } from './session-trace-state'

const baseSummary: TraceSummary = {
  tool_call_count: 0,
  oas_tool_count: 0,
  oas_turn_count: 0,
  oas_context_count: 0,
  broadcast_count: 0,
  task_completed_count: 0,
  task_claimed_count: 0,
  heartbeat_count: 0,
  lifecycle_count: 0,
  thinking_count: 0,
  total_cost_usd: 0,
  oas_input_tokens: 0,
  oas_output_tokens: 0,
  oas_cache_creation_tokens: 0,
  oas_cache_read_tokens: 0,
  oas_cache_miss_input_tokens: 0,
  oas_llm_call_count: 0,
  oas_error_count: 0,
  oas_tokens_saved: 0,
}

function summary(overrides: Partial<TraceSummary> = {}): TraceSummary {
  return { ...baseSummary, ...overrides }
}

function event(overrides: Partial<UnifiedTraceEvent> = {}): UnifiedTraceEvent {
  const ts = overrides.ts ?? 1_000_000
  return {
    id: overrides.id ?? `evt-${ts}-${overrides.summary ?? overrides.toolName ?? 'trace'}`,
    ts,
    ts_iso: overrides.ts_iso ?? new Date(ts).toISOString(),
    kind: overrides.kind ?? 'tool_call',
    sourceLane: overrides.sourceLane ?? 'masc',
    summary: overrides.summary ?? overrides.toolName ?? 'Read',
    detail: overrides.detail ?? {},
    ...overrides,
  }
}

function ids(findings: readonly ProcessCriticFinding[]): string[] {
  return findings.map(finding => finding.id)
}

const advisoryFindingFields = ['action', 'detail', 'evidence', 'id', 'severity', 'title']
const advisorySeverities = ['action', 'warning', 'notice']

describe('evaluateProcessTrace', () => {
  it('returns no findings for an empty trace', () => {
    expect(evaluateProcessTrace({ events: [], summary: summary() })).toEqual([])
  })

  it('prioritizes recent failures as an action finding', () => {
    const findings = evaluateProcessTrace({
      events: [
        event({ summary: 'exec', toolName: 'exec', error: 'HTTP 429' }),
      ],
      summary: summary({ tool_call_count: 1 }),
    })

    expect(findings[0]).toMatchObject({
      id: 'recent-failure-boundary',
      severity: 'action',
      action: 'Inspect latest error',
    })
    expect(findings[0]?.evidence[0]).toContain('HTTP 429')
  })

  it('keeps findings advisory-only without control fields', () => {
    const findings = evaluateProcessTrace({
      events: [
        event({ summary: 'exec', toolName: 'exec', error: 'HTTP 429' }),
      ],
      summary: summary({ tool_call_count: 1 }),
    })

    expect(findings).not.toHaveLength(0)
    for (const finding of findings) {
      expect(Object.keys(finding).sort()).toEqual(advisoryFindingFields)
      expect(advisorySeverities).toContain(finding.severity)
    }
  })

  it('detects repeated short tool loops', () => {
    const events = [0, 1, 2, 3].map(index =>
      event({
        id: `exec-${index}`,
        summary: 'exec',
        toolName: 'exec',
        duration_ms: 500,
        ts: 2_000_000 - index,
      }),
    )

    const findings = evaluateProcessTrace({
      events,
      summary: summary({ tool_call_count: 4 }),
    })

    expect(findings[0]).toMatchObject({
      id: 'repeated-tool-loop',
      severity: 'action',
      action: 'Narrow query or line range',
    })
    expect(findings[0]?.detail).toContain('4 times')
    expect(findings[0]?.evidence).toEqual(['exec 500ms', 'exec 500ms', 'exec 500ms', 'exec 500ms'])
  })

  it('flags context compaction as process pressure', () => {
    const findings = evaluateProcessTrace({
      events: [
        event({ kind: 'oas_context', summary: 'OAS compact', detail: { before_tokens: 180_000, after_tokens: 90_000 } }),
      ],
      summary: summary({ oas_context_count: 1, oas_tokens_saved: 90_000 }),
    })

    expect(ids(findings)).toContain('context-pressure')
    expect(findings.find(finding => finding.id === 'context-pressure')?.evidence).toEqual([
      'context compactions 1',
      'tokens saved 90000',
    ])
  })

  it('caps noisy traces to three advisory findings', () => {
    const nowMs = 10 * 60 * 1000
    const repeated = [0, 1, 2].map(index =>
      event({
        id: `exec-${index}`,
        summary: 'exec',
        toolName: 'exec',
        duration_ms: 500,
        error: index === 0 ? 'boom' : null,
        ts: 1_000,
      }),
    )

    const findings = evaluateProcessTrace({
      events: repeated,
      summary: summary({
        tool_call_count: 8,
        oas_context_count: 1,
        oas_error_count: 1,
      }),
      nowMs,
    })

    expect(findings).toHaveLength(3)
    expect(ids(findings)).toEqual([
      'recent-failure-boundary',
      'repeated-tool-loop',
      'context-pressure',
    ])
  })
})
