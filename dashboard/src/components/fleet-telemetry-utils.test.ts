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
  buildFleetRows,
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
    cascade_label: null,
    provider_label: null,
    fallback_label: null,
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
    provider_health_status: null,
    provider_health_label: null,
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
    expect(isPlaceholderModel('default')).toBe(true)
    expect(isPlaceholderModel('auto')).toBe(true)
  })

  it('returns false for real model names', () => {
    expect(isPlaceholderModel('claude-sonnet-4-6')).toBe(false)
    expect(isPlaceholderModel('gpt-4o')).toBe(false)
    expect(isPlaceholderModel('claude_code:auto')).toBe(false)
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

describe('buildFleetRows runtime labels', () => {
  it('surfaces cascade, provider, and fallback labels from keeper telemetry', () => {
    const [row] = buildFleetRows([
      {
        name: 'cascade-keeper',
        status: 'active',
        keepalive_running: true,
        cascade_name: 'oas-keeper_unified',
        cascade_canonical: 'primary',
        active_model_label: 'codex_cli:auto',
        trust: {
          execution_summary: {
            provider_selected_model: 'anthropic:claude-sonnet-4-6',
            provider_attempt_count: 2,
            provider_fallback_applied: true,
            cascade_outcome: 'passed_to_next_model',
          },
        },
        metrics_series: [
          {
            ts: 10,
            context_ratio: 0.42,
            context_tokens: 420,
            context_max: 1000,
            latency_ms: 100,
            generation: 1,
            channel: 'turn',
            is_handoff: false,
            is_compaction: false,
            compaction_saved_tokens: 0,
            compaction_trigger: null,
            model_used: 'anthropic:claude-sonnet-4-6',
            cost_usd: 0,
            handoff_to_model: null,
            handoff_new_generation: null,
            prompt_fingerprint: null,
            prompt_metrics: null,
            timeout_budget: null,
            ctx_composition: null,
            input_tokens: null,
            output_tokens: null,
            total_tokens: null,
            wall_tokens_per_second: null,
            inference_telemetry: null,
            cascade_name: 'primary',
            cascade_selected_model: 'anthropic:claude-sonnet-4-6',
            cascade_attempt_count: 2,
            cascade_outcome: 'passed_to_next_model',
            cascade_strategy: 'round_robin',
            fallback_applied: true,
            fallback_hops: 1,
            fallback_from: 'openai:gpt-5.4',
            fallback_to: 'anthropic:claude-sonnet-4-6',
            fallback_reason: 'turn_timeout',
          },
        ],
      },
    ], {
      total: 0,
      success: 0,
      failure: 0,
      success_rate: 0,
      by_tool: [],
      by_keeper: [],
      failure_categories: [],
      hourly_trend: [],
    })

    expect(row).toMatchObject({
      model: 'codex_cli:auto',
      cascade_label: 'oas-keeper_unified -> primary',
      provider_label: 'anthropic:claude-sonnet-4-6 · 2 attempts · fallback',
      fallback_label: 'openai:gpt-5.4 -> anthropic:claude-sonnet-4-6 · turn_timeout · 1 hops',
    })
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
    expect(toolSummary(row).label).toContain('최근 도구 기록 없음')
  })

  it('shows unavailable when activity unknown', () => {
    const row = makeRow({ recent_tools: [], tool_calls: 0, tool_activity_known: false })
    expect(toolSummary(row).label).toMatch(/unavailable|없음/i)
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

describe('buildFleetRows', () => {
  it('does not turn tool-quality-only data into runtime fleet rows', () => {
    const rows = buildFleetRows([], {
      total: 5,
      success: 5,
      failure: 0,
      success_rate: 100,
      by_tool: [],
      by_keeper: [
        { name: 'keeper-tool-only', calls: 5, success_pct: 100 },
      ],
      failure_categories: [],
      hourly_trend: [],
    })

    expect(rows).toEqual([])
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
