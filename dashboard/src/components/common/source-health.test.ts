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
      'tool_call_io_append_failed',
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
      summary: 'coverage gaps 2: tool_call_io_append_failed',
      details: [
        'producer keeper_tool_call_log.append',
        'store .masc/tool_calls',
        'surface /api/v1/keepers/:name/tool-calls',
        'trace trace-tool-call-gap',
        'error append denied',
      ],
      structured: {
        reason: 'tool_call_io_append_failed',
        fields: [
          { label: 'producer', value: 'keeper_tool_call_log.append' },
          { label: 'store', value: '.masc/tool_calls' },
          { label: 'surface', value: '/api/v1/keepers/:name/tool-calls' },
          { label: 'trace', value: 'trace-tool-call-gap' },
        ],
        error: 'append denied',
        errorClass: null,
      },
    })
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
      summary: 'coverage gaps 2: NEW_reason',
      details: [
        'producer NEW-producer',
        'store NEW-store',
        'surface NEW-surface',
        'trace NEW-trace',
        'error NEW-error',
      ],
      structured: {
        reason: 'NEW_reason',
        fields: [
          { label: 'producer', value: 'NEW-producer' },
          { label: 'store', value: 'NEW-store' },
          { label: 'surface', value: 'NEW-surface' },
          { label: 'trace', value: 'NEW-trace' },
        ],
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
