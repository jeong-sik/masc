import { describe, expect, it } from 'vitest'

import {
  PRESSURE_HOT_RATIO,
  PRESSURE_WARN_RATIO,
  STALE_ACTIVITY_SEC,
  normalizeText,
  isPlaceholderModel,
  normalizeModelText,
  firstNonEmptyString,
  uniqueStrings,
  successClass,
  fleetBand,
  fleetBandScore,
  rowUrgencyScore,
  compareFleetRows,
  pressureClass,
  statusClass,
  formatPercent,
  formatLatency,
  formatActivity,
  formatActivitySignal,
  numericAge,
  toneForToolSuccess,
  toneForPressure,
  toolSummary,
  summaryCounts,
  buildToolQualityMap,
  buildRuntimeWarnings,
  emptyState,
  type FleetRow,
} from './fleet-telemetry-utils'

// --- Helpers ---

function makeRow(overrides: Partial<FleetRow> = {}): FleetRow {
  return {
    name: 'test-keeper',
    status: 'active',
    keepalive_running: true,
    diagnostic_health_state: null,
    diagnostic_summary: null,
    context_ratio: 0.3,
    turn_count: 10,
    last_latency_ms: 500,
    last_activity_ago_s: 60,
    activity_label: '최근 활동',
    activity_source: 'last_activity',
    model: 'test-model',
    tool_calls: 5,
    tool_success_pct: 95,
    tool_activity_known: true,
    recent_tools: ['tool_a'],
    runtime_blocker_class: null,
    runtime_blocker_summary: null,
    tool_audit_at: null,
    goal_label: null,
    goal_linked: false,
    active_goal_count: 0,
    sandbox_profile: null,
    sandbox_last_error: null,
    effective_sandbox_image: null,
    decision_required: false,
    budget_source: null,
    ...overrides,
  }
}

// --- Tests ---

describe('normalizeText', () => {
  it('returns null for null/undefined', () => {
    expect(normalizeText(null)).toBeNull()
    expect(normalizeText(undefined)).toBeNull()
  })

  it('returns null for whitespace-only strings', () => {
    expect(normalizeText('   ')).toBeNull()
    expect(normalizeText('')).toBeNull()
  })

  it('trims and returns non-empty strings', () => {
    expect(normalizeText('  hello  ')).toBe('hello')
  })
})

describe('isPlaceholderModel', () => {
  it('recognizes placeholder values', () => {
    expect(isPlaceholderModel('unknown')).toBe(true)
    expect(isPlaceholderModel('none')).toBe(true)
    expect(isPlaceholderModel('-')).toBe(true)
    expect(isPlaceholderModel('n/a')).toBe(true)
  })

  it('returns false for real model names', () => {
    expect(isPlaceholderModel('claude-sonnet-4-6')).toBe(false)
    expect(isPlaceholderModel('gpt-4o')).toBe(false)
  })

  it('is case-insensitive', () => {
    expect(isPlaceholderModel('Unknown')).toBe(true)
    expect(isPlaceholderModel('NONE')).toBe(true)
  })
})

describe('normalizeModelText', () => {
  it('returns null for null/undefined/placeholder', () => {
    expect(normalizeModelText(null)).toBeNull()
    expect(normalizeModelText(undefined)).toBeNull()
    expect(normalizeModelText('unknown')).toBeNull()
    expect(normalizeModelText('n/a')).toBeNull()
  })

  it('returns trimmed text for valid models', () => {
    expect(normalizeModelText(' claude-sonnet-4-6 ')).toBe('claude-sonnet-4-6')
  })
})

describe('firstNonEmptyString', () => {
  it('returns first non-null trimmed string', () => {
    expect(firstNonEmptyString(null, '  ', 'hello', 'world')).toBe('hello')
  })

  it('returns null when all are empty', () => {
    expect(firstNonEmptyString(null, undefined, '  ')).toBeNull()
  })
})

describe('uniqueStrings', () => {
  it('deduplicates and trims', () => {
    expect(uniqueStrings(['a', '  a  ', 'b', null, 'b'])).toEqual(['a', 'b'])
  })

  it('filters null/undefined/empty', () => {
    expect(uniqueStrings([null, undefined, '  ', 'x'])).toEqual(['x'])
  })
})

describe('successClass', () => {
  it('returns ok for >=97', () => {
    expect(successClass(97)).toContain('var(--color-status-ok)')
    expect(successClass(100)).toContain('var(--color-status-ok)')
  })

  it('returns warn for 90-96', () => {
    expect(successClass(90)).toContain('var(--color-status-warn)')
    expect(successClass(96)).toContain('var(--color-status-warn)')
  })

  it('returns bad-light for <90', () => {
    expect(successClass(89)).toContain('var(--bad-light)')
    expect(successClass(50)).toContain('var(--bad-light)')
  })

  it('returns disabled for null/non-finite', () => {
    expect(successClass(null)).toContain('color-fg-disabled')
    expect(successClass(NaN)).toContain('color-fg-disabled')
  })
})

describe('fleetBand', () => {
  it('classifies offline when keepalive not running', () => {
    expect(fleetBand(makeRow({ keepalive_running: false }))).toBe('offline')
  })

  it('classifies offline for dead/stopped/crashed status', () => {
    expect(fleetBand(makeRow({ status: 'dead' }))).toBe('offline')
    expect(fleetBand(makeRow({ status: 'stopped' }))).toBe('offline')
    expect(fleetBand(makeRow({ status: 'crashed' }))).toBe('offline')
  })

  it('classifies paused', () => {
    expect(fleetBand(makeRow({ status: 'paused' }))).toBe('paused')
  })

  it('classifies inactive keepalive rows as attention, not offline', () => {
    expect(fleetBand(makeRow({ status: 'inactive', keepalive_running: true }))).toBe('attention')
  })

  it('classifies attention for stale diagnostic health state', () => {
    expect(fleetBand(makeRow({ status: 'inactive', diagnostic_health_state: 'stale' }))).toBe('attention')
  })

  it('classifies attention for runtime blocker', () => {
    expect(fleetBand(makeRow({ runtime_blocker_class: 'admission_queue_wait_timeout' }))).toBe('attention')
  })

  it('classifies attention for high context ratio', () => {
    expect(fleetBand(makeRow({ context_ratio: PRESSURE_WARN_RATIO }))).toBe('attention')
  })

  it('classifies attention for stale activity', () => {
    expect(fleetBand(makeRow({ last_activity_ago_s: STALE_ACTIVITY_SEC }))).toBe('attention')
  })

  it('classifies attention for low tool success', () => {
    expect(fleetBand(makeRow({ tool_success_pct: 85 }))).toBe('attention')
  })

  it('classifies active for healthy row', () => {
    expect(fleetBand(makeRow())).toBe('active')
  })
})

describe('fleetBandScore', () => {
  it('orders attention > active > paused > offline', () => {
    const attention = makeRow({ runtime_blocker_class: 'admission_queue_wait_timeout' })
    const active = makeRow()
    const paused = makeRow({ status: 'paused' })
    const offline = makeRow({ keepalive_running: false })

    expect(fleetBandScore(attention)).toBeGreaterThan(fleetBandScore(active))
    expect(fleetBandScore(active)).toBeGreaterThan(fleetBandScore(paused))
    expect(fleetBandScore(paused)).toBeGreaterThan(fleetBandScore(offline))
  })
})

describe('rowUrgencyScore', () => {
  it('scores runtime blocker highest', () => {
    const withBlocker = makeRow({ runtime_blocker_class: 'turn_timeout' })
    const without = makeRow()
    expect(rowUrgencyScore(withBlocker)).toBeGreaterThan(rowUrgencyScore(without))
  })

  it('increases with context ratio', () => {
    const highCtx = makeRow({ context_ratio: 0.8 })
    const lowCtx = makeRow({ context_ratio: 0.2 })
    expect(rowUrgencyScore(highCtx)).toBeGreaterThan(rowUrgencyScore(lowCtx))
  })
})

describe('compareFleetRows', () => {
  it('sorts by band score descending', () => {
    const a = makeRow({ name: 'a', runtime_blocker_class: 'turn_timeout' })
    const b = makeRow({ name: 'b' })
    expect(compareFleetRows(a, b)).toBeLessThan(0) // attention before active
  })

  it('breaks ties by name ascending', () => {
    const a = makeRow({ name: 'alpha' })
    const b = makeRow({ name: 'beta' })
    expect(compareFleetRows(a, b)).toBeLessThan(0)
  })
})

describe('pressureClass', () => {
  // After the Anyang Sleepers token migration, pressureClass returns
  // semantic design-system tokens (--bad-light / --warn / --ok)
  // rather than hardcoded Tailwind colors, so the chip recolors
  // automatically under [data-theme="paper"].
  it('returns bad-light for hot ratio', () => {
    expect(pressureClass(PRESSURE_HOT_RATIO)).toContain('var(--bad-light)')
  })

  it('returns warn for warn ratio', () => {
    expect(pressureClass(PRESSURE_WARN_RATIO)).toContain('var(--color-status-warn)')
  })

  it('returns ok for low ratio', () => {
    expect(pressureClass(0.1)).toContain('var(--color-status-ok)')
  })
})

describe('statusClass', () => {
  it('returns bad-light for offline/stopped', () => {
    expect(statusClass(makeRow({ keepalive_running: false }))).toContain('var(--bad-light)')
    expect(statusClass(makeRow({ status: 'stopped' }))).toContain('var(--bad-light)')
  })

  it('returns warn for runtime blocker', () => {
    expect(statusClass(makeRow({ runtime_blocker_class: 'turn_timeout' }))).toContain('var(--color-status-warn)')
  })

  it('returns warn for stale diagnostic health state', () => {
    expect(statusClass(makeRow({ status: 'inactive', diagnostic_health_state: 'stale' }))).toContain('var(--color-status-warn)')
  })

  it('returns bad-light for offline diagnostic health state', () => {
    expect(statusClass(makeRow({ status: 'inactive', diagnostic_health_state: 'offline' }))).toContain('var(--bad-light)')
  })

  it('returns ok for healthy', () => {
    expect(statusClass(makeRow())).toContain('var(--color-status-ok)')
  })
})

describe('formatPercent', () => {
  it('formats valid numbers', () => {
    expect(formatPercent(95.5, 1)).toBe('95.5%')
    expect(formatPercent(100)).toBe('100%')
  })

  it('returns dash for null/non-finite', () => {
    expect(formatPercent(null)).toBe('-')
    expect(formatPercent(NaN)).toBe('-')
  })
})

describe('formatLatency', () => {
  it('formats milliseconds', () => {
    expect(formatLatency(500)).toBe('500ms')
  })

  it('formats seconds', () => {
    expect(formatLatency(1500)).toBe('1.5s')
  })

  it('returns dash for zero/negative/non-finite', () => {
    expect(formatLatency(0)).toBe('-')
    expect(formatLatency(-1)).toBe('-')
    expect(formatLatency(NaN)).toBe('-')
  })
})

describe('formatActivity', () => {
  it('returns dash for null/negative', () => {
    expect(formatActivity(null)).toBe('-')
    expect(formatActivity(-1)).toBe('-')
  })
})

describe('formatActivitySignal', () => {
  it('prefixes the age with the selected keeper activity label', () => {
    expect(formatActivitySignal(makeRow({ activity_label: '하트비트', last_activity_ago_s: 360 }))).toBe('하트비트 6m 0s')
  })

  it('returns dash when the activity age is unknown', () => {
    expect(formatActivitySignal(makeRow({ last_activity_ago_s: null }))).toBe('-')
  })
})

describe('numericAge', () => {
  it('returns null for non-finite values', () => {
    expect(numericAge(null)).toBeNull()
    expect(numericAge(undefined)).toBeNull()
    expect(numericAge(NaN)).toBeNull()
    expect(numericAge(-1)).toBeNull()
  })

  it('returns valid ages', () => {
    expect(numericAge(0)).toBe(0)
    expect(numericAge(300)).toBe(300)
  })
})

describe('toneForToolSuccess', () => {
  it('returns ok for >=97', () => {
    expect(toneForToolSuccess(97)).toBe('ok')
    expect(toneForToolSuccess(100)).toBe('ok')
  })

  it('returns neutral for 90-96', () => {
    expect(toneForToolSuccess(90)).toBe('neutral')
    expect(toneForToolSuccess(96)).toBe('neutral')
  })

  it('returns warn for <90', () => {
    expect(toneForToolSuccess(89)).toBe('warn')
  })
})

describe('toneForPressure', () => {
  it('returns warn when hot > 0', () => {
    expect(toneForPressure(1, 0)).toBe('warn')
  })

  it('returns neutral when warn > 0', () => {
    expect(toneForPressure(0, 1)).toBe('neutral')
  })

  it('returns ok when neither', () => {
    expect(toneForPressure(0, 0)).toBe('ok')
  })
})

describe('toolSummary', () => {
  it('shows recent tools when available', () => {
    const row = makeRow({ recent_tools: ['bash', 'grep'] })
    const summary = toolSummary(row)
    expect(summary.label).toBe('bash, grep')
  })

  it('shows call count when no tool names', () => {
    const row = makeRow({ recent_tools: [], tool_calls: 42 })
    expect(toolSummary(row).label).toContain('42')
  })

  it('shows no recent tools when activity known but nothing', () => {
    const row = makeRow({ recent_tools: [], tool_calls: 0, tool_activity_known: true })
    expect(toolSummary(row).label).toContain('No recent tools')
  })

  it('shows unavailable when activity unknown', () => {
    const row = makeRow({ recent_tools: [], tool_calls: 0, tool_activity_known: false })
    expect(toolSummary(row).label).toContain('unavailable')
  })
})

describe('summaryCounts', () => {
  it('counts live, hot, warn, stale correctly', () => {
    const rows = [
      makeRow({ name: 'a', keepalive_running: true, context_ratio: 0.1, last_activity_ago_s: 60, tool_calls: 1 }),
      makeRow({ name: 'b', keepalive_running: true, context_ratio: PRESSURE_HOT_RATIO, last_activity_ago_s: 60, tool_calls: 0, recent_tools: [] }),
      makeRow({ name: 'c', keepalive_running: false, context_ratio: 0.1, last_activity_ago_s: null, tool_calls: 0, recent_tools: [] }),
    ]
    const counts = summaryCounts(rows)
    expect(counts.live).toBe(2)
    expect(counts.hot).toBe(1)
    expect(counts.toolCovered).toBe(1)
  })
})

describe('buildToolQualityMap', () => {
  it('maps keeper names to stats', () => {
    const map = buildToolQualityMap({
      total: 10,
      success: 8,
      failure: 2,
      success_rate: 80,
      by_tool: [],
      by_keeper: [
        { name: 'janitor', calls: 5, success_pct: 80 },
        { name: 'guardian', calls: 5, success_pct: 80 },
      ],
      failure_categories: [],
      hourly_trend: [],
    })
    expect(map.get('janitor')!.calls).toBe(5)
    expect(map.get('guardian')!.success_pct).toBe(80)
    expect(map.has('unknown')).toBe(false)
  })
})

describe('buildRuntimeWarnings', () => {
  it('warns about admission queue blockage', () => {
    const rows = [makeRow({ runtime_blocker_class: 'admission_queue_wait_timeout' })]
    const warnings = buildRuntimeWarnings(rows)
    expect(warnings.length).toBe(1)
    expect(warnings[0]).toContain('admission queue')
  })

  it('warns about slot blockage', () => {
    const rows = [makeRow({ runtime_blocker_class: 'autonomous_slot_wait_timeout' })]
    const warnings = buildRuntimeWarnings(rows)
    expect(warnings.length).toBe(1)
    expect(warnings[0]).toContain('autonomous cycle')
  })

  it('warns about other blockers', () => {
    const rows = [makeRow({ runtime_blocker_class: 'turn_timeout_after_queue_wait' })]
    const warnings = buildRuntimeWarnings(rows)
    expect(warnings.length).toBe(1)
    expect(warnings[0]).toContain('other runtime blockers')
  })

  it('returns empty for healthy rows', () => {
    expect(buildRuntimeWarnings([makeRow()])).toEqual([])
  })
})

describe('emptyState', () => {
  it('returns valid initial state', () => {
    const state = emptyState()
    expect(state.loading).toBe(false)
    expect(state.error).toBeNull()
    expect(state.rows).toEqual([])
    expect(state.warnings).toEqual([])
    expect(state.tool_quality.total).toBe(0)
  })
})
