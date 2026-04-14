import { describe, expect, it } from 'vitest'
import type { LogEntry } from '../api/dashboard'
import { failureEnvelope, mergeLogEntries, renderLogMessage } from './logs'

function entry(seq: number, overrides: Partial<LogEntry> = {}): LogEntry {
  return {
    seq,
    ts: `2026-03-24T00:00:${String(seq).padStart(2, '0')}Z`,
    level: 'INFO',
    raw_level: 'INFO',
    normalized_level: 'INFO',
    source: 'structured',
    legacy_classified: false,
    module: 'Dashboard',
    message: `entry-${seq}`,
    details: null,
    ...overrides,
  }
}

describe('mergeLogEntries', () => {
  it('deduplicates by seq and keeps newest payload', () => {
    const current = [entry(5, { message: 'old-5' }), entry(4)]
    const incoming = [entry(6), entry(5, { message: 'new-5', source: 'legacy_stderr' })]

    expect(mergeLogEntries(current, incoming, 10)).toEqual([
      entry(6),
      entry(5, { message: 'new-5', source: 'legacy_stderr' }),
      entry(4),
    ])
  })

  it('trims merged output to the requested maximum', () => {
    const current = [entry(4), entry(3), entry(2)]
    const incoming = [entry(5), entry(1)]

    expect(mergeLogEntries(current, incoming, 3).map(item => item.seq)).toEqual([5, 4, 3])
  })
})

describe('failureEnvelope', () => {
  it('parses a valid envelope from log details', () => {
    const parsed = failureEnvelope(
      entry(7, {
        details: {
          failure_envelope: {
            surface: 'tool_host',
            entity_kind: 'tool_call',
            entity_id: 'req-7',
            cause_code: 'tool_host_timeout',
            severity: 'bad',
            summary: 'codex masc_keeper_msg failed during tools/call on mcp_http',
            recoverability: 'operator_action_required',
            operator_action: 'masc_operator_digest',
            evidence_ref: {
              request_id: 'req-7',
              tool_name: 'masc_keeper_msg',
            },
          },
        },
      }),
    )

    expect(parsed).toEqual({
      surface: 'tool_host',
      entity_kind: 'tool_call',
      entity_id: 'req-7',
      cause_code: 'tool_host_timeout',
      severity: 'bad',
      summary: 'codex masc_keeper_msg failed during tools/call on mcp_http',
      recoverability: 'operator_action_required',
      operator_action: 'masc_operator_digest',
      evidence_ref: {
        request_id: 'req-7',
        tool_name: 'masc_keeper_msg',
      },
    })
  })

  it('returns null for malformed envelopes', () => {
    expect(
      failureEnvelope(
        entry(8, {
          details: {
            failure_envelope: {
              surface: 'tool_host',
              cause_code: 'tool_host_timeout',
            },
          },
        }),
      ),
    ).toBeNull()
  })
})

describe('renderLogMessage', () => {
  it('interpolates structured printf-style placeholders from details', () => {
    expect(
      renderLogMessage(
        entry(9, {
          module: 'oas:agent_tools',
          message: 'tool %s: correction_pipeline fixed %d field(s)',
          details: {
            tool: 'keeper_github',
            fixes: 2,
          },
        }),
      ),
    ).toBe('tool keeper_github: correction_pipeline fixed 2 field(s)')
  })
})
