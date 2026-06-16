import { describe, expect, it } from 'vitest'

import { coverageGapDisplay, freshnessText, sourceHealthClass } from './source-health'

describe('sourceHealthClass', () => {
  it('maps coverage_gap to warning tone', () => {
    expect(sourceHealthClass('coverage_gap')).toBe('text-[var(--color-status-warn)]')
  })
})

describe('freshnessText', () => {
  it('prefers stale reason over latest age', () => {
    expect(freshnessText({ stale_reason: 'tool_call_io_append_failed', latest_age_s: 4 })).toBe(
      'tool-call log write failed',
    )
  })
})

describe('coverageGapDisplay', () => {
  it('summarizes latest coverage gap provenance for freshness lines', () => {
    const display = coverageGapDisplay({
      source: 'tool_call_io',
      producer: 'fallback-producer',
      durable_store: 'fallback-store',
      dashboard_surface: 'fallback-surface',
      stale_reason: 'fallback_reason',
      coverage_gap_count: 2,
      coverage_gaps: [
        {
          source: 'tool_call_io',
          producer: 'keeper_tool_call_log.append',
          durable_store: '.masc/tool_calls',
          dashboard_surface: '/api/v1/keepers/:name/tool-calls',
          stale_reason: 'tool_call_io_append_failed',
          trace_id: 'trace-tool-call-gap',
          error: 'append denied',
        },
      ],
    })

    expect(display).toEqual({
      count: 2,
      summary: 'Tool-call log write failed · 2 recorded gaps',
      details: [
        'status recorded',
        'impact Tool Monitor may undercount keeper tool I/O around this trace.',
        'reason tool_call_io_append_failed',
        'producer keeper_tool_call_log.append',
        'store .masc/tool_calls',
        'surface /api/v1/keepers/:name/tool-calls',
        'trace trace-tool-call-gap',
        'error append denied',
      ],
      structured: {
        reason: 'tool_call_io_append_failed',
        title: 'Tool-call log write failed',
        stateLabel: 'recorded',
        latest: null,
        impact: 'Tool Monitor may undercount keeper tool I/O around this trace.',
        producer: 'keeper_tool_call_log.append',
        store: '.masc/tool_calls',
        surface: '/api/v1/keepers/:name/tool-calls',
        trace: 'trace-tool-call-gap',
        error: 'append denied',
        errorClass: null,
      },
    })
  })

  it('appends the active (unrecovered) count when it is a strict subset of the total', () => {
    const display = coverageGapDisplay({
      source: 'tool_call_io',
      stale_reason: 'tool_call_io_append_failed',
      coverage_gap_count: 3,
      active_coverage_gap_count: 1,
    })
    expect(display?.summary).toBe('Tool-call log write failed · 3 recorded gaps · 1 active')
  })

  it('omits the active suffix when all gaps are active or none are', () => {
    const allActive = coverageGapDisplay({
      source: 'tool_call_io',
      stale_reason: 'tool_call_io_append_failed',
      coverage_gap_count: 2,
      active_coverage_gap_count: 2,
    })
    expect(allActive?.summary).toBe('Tool-call log write failed · 2 recorded gaps')
    const noneActive = coverageGapDisplay({
      source: 'tool_call_io',
      stale_reason: 'tool_call_io_append_failed',
      coverage_gap_count: 2,
      active_coverage_gap_count: 0,
    })
    expect(noneActive?.summary).toBe('Tool-call log write failed · 2 recorded gaps')
  })

  it('selects the newest gap (last element) when multiple gaps are present', () => {
    // Backends emit coverage_gaps in oldest→newest order; the UI must show the
    // most recent incident, not the first one in the list.
    const display = coverageGapDisplay({
      source: 'tool_call_io',
      coverage_gap_count: 2,
      coverage_gaps: [
        {
          source: 'tool_call_io',
          producer: 'OLD-producer',
          durable_store: 'OLD-store',
          dashboard_surface: 'OLD-surface',
          stale_reason: 'OLD_reason',
          trace_id: 'OLD-trace',
          error: 'OLD-error',
        },
        {
          source: 'tool_call_io',
          producer: 'NEW-producer',
          durable_store: 'NEW-store',
          dashboard_surface: 'NEW-surface',
          stale_reason: 'NEW_reason',
          trace_id: 'NEW-trace',
          error: 'NEW-error',
        },
      ],
    })

    expect(display).toEqual({
      count: 2,
      summary: 'Tool-call telemetry coverage issue · 2 recorded gaps',
      details: [
        'status recorded',
        'impact Tool Monitor may undercount keeper tool I/O around this trace.',
        'reason NEW_reason',
        'producer NEW-producer',
        'store NEW-store',
        'surface NEW-surface',
        'trace NEW-trace',
        'error NEW-error',
      ],
      structured: {
        reason: 'NEW_reason',
        title: 'Tool-call telemetry coverage issue',
        stateLabel: 'recorded',
        latest: null,
        impact: 'Tool Monitor may undercount keeper tool I/O around this trace.',
        producer: 'NEW-producer',
        store: 'NEW-store',
        surface: 'NEW-surface',
        trace: 'NEW-trace',
        error: 'NEW-error',
        errorClass: null,
      },
    })
  })

  it('threads backend error_class through structured.errorClass (RFC-0154 PR-3)', () => {
    const display = coverageGapDisplay({
      source: 'tool_call_io',
      coverage_gap_count: 1,
      coverage_gaps: [
        {
          source: 'tool_call_io',
          producer: 'p',
          durable_store: 's',
          dashboard_surface: 'd',
          stale_reason: 'tool_call_io_append_failed',
          trace_id: 't',
          error: 'Sys_error: too many open files',
          error_class: 'fd_exhaustion',
        },
      ],
    })
    expect(display?.structured.errorClass).toBe('fd_exhaustion')
  })
})
