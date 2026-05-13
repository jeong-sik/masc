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
    })
  })
})
