import { describe, expect, it } from 'vitest'
import type { LogEntry } from '../api/dashboard'
import { logDiagnosticCause, summarizeLogWindow } from './logs'

function entry(overrides: Partial<LogEntry>): LogEntry {
  return {
    seq: 1,
    ts: '2026-05-14T00:00:00Z',
    level: 'INFO',
    raw_level: 'INFO',
    normalized_level: 'INFO',
    source: 'structured',
    legacy_classified: false,
    module: 'Keeper',
    message: 'ok',
    details: null,
    ...overrides,
  }
}

describe('log diagnostics', () => {
  it('classifies timeout and cascade messages without structured envelopes', () => {
    expect(
      logDiagnosticCause(
        entry({
          level: 'WARN',
          normalized_level: 'WARN',
          message:
            'keeper_llm_bridge: OAS execution timed out after 300.0s (budget=300s)',
        }),
      ),
    ).toBe('oas_timeout_budget')

    expect(
      logDiagnosticCause(
        entry({
          level: 'ERROR',
          normalized_level: 'ERROR',
          message:
            'all cascades exhausted: Cascade attempt liveness guard killed runtime lane coding_plan: inter_chunk_idle',
        }),
      ),
    ).toBe('inter_chunk_idle')
  })

  it('classifies keeper telemetry and registry noise causes', () => {
    expect(
      logDiagnosticCause(
        entry({
          level: 'INFO',
          normalized_level: 'INFO',
          message:
            'keeper:analyst after_turn usage telemetry unavailable runtime_lane=runtime reasons=zero_token_usage_reported input=0 output=0 context_max=200000',
        }),
      ),
    ).toBe('usage_zero_tokens')

    expect(
      logDiagnosticCause(
        entry({
          level: 'WARN',
          normalized_level: 'WARN',
          message:
            'registry: orphan threshold breached name=analyst base_path=/Users/dancer/me drops=5 window=60s',
        }),
      ),
    ).toBe('registry_orphan_threshold')
  })

  it('prefers failure envelope cause codes and summarizes the current window', () => {
    const entries = [
      entry({
        seq: 3,
        level: 'ERROR',
        normalized_level: 'ERROR',
        module: 'Keeper',
        message: 'keeper_llm_bridge timeout',
        details: {
          failure_envelope: {
            surface: 'keeper_oas_bridge',
            entity_kind: 'oas_execution',
            entity_id: null,
            cause_code: 'oas_timeout_budget',
            severity: 'bad',
            summary: 'OAS execution exceeded budget',
            recoverability: 'operator_action_required',
            operator_action: 'inspect_timeout_budget',
            evidence_ref: { timeout_sec: 300 },
          },
        },
      }),
      entry({
        seq: 2,
        level: 'WARN',
        normalized_level: 'WARN',
        module: 'Task',
        message: 'Ignoring legacy verification directory /tmp/verifications',
      }),
      entry({
        seq: 1,
        level: 'INFO',
        normalized_level: 'INFO',
        module: 'Keeper',
        message: 'normal',
      }),
    ]

    const summary = summarizeLogWindow(entries)
    expect(summary.errors).toBe(1)
    expect(summary.warnings).toBe(1)
    expect(summary.failureEnvelopes).toBe(1)
    expect(summary.topCauses).toContainEqual({ cause: 'oas_timeout_budget', count: 1 })
    expect(summary.topCauses).toContainEqual({
      cause: 'legacy_verification_dir',
      count: 1,
    })
    expect(summary.topModules[0]).toEqual({ module: 'Keeper', count: 2 })
  })
})
