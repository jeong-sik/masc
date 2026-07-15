import { describe, expect, it } from 'vitest'

import {
  PRESSURE_HOT_RATIO,
  PRESSURE_WARN_RATIO,
  STALE_ACTIVITY_SEC,
  normalizeText,
  isPlaceholderModel,
  normalizeModelText,
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
  sourceDetail,
  toneForToolSuccess,
  toneForPressure,
  toolSummary,
  summaryCounts,
  toolTelemetryCoverageDetail,
  buildToolQualityMap,
  buildFleetRows,
  buildRuntimeWarnings,
  EMPTY_TOOL_QUALITY,
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
    runtime_label: null,
    provider_label: null,
    fallback_label: null,
    tool_calls: 5,
    tool_success_pct: 95,
    tool_activity_known: true,
    recent_tools: ['tool_a'],
    runtime_blocker_class: null,
    runtime_blocker_summary: null,
    tool_audit_at: null,
    sandbox_profile: null,
    sandbox_last_error: null,
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
    expect(isPlaceholderModel('claude-sonnet')).toBe(false)
    expect(isPlaceholderModel('gpt')).toBe(false)
    expect(isPlaceholderModel('claude-code:auto')).toBe(false)
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
    expect(normalizeModelText(' claude-sonnet ')).toBe('claude-sonnet')
  })
})

describe('sourceDetail', () => {
  it('includes telemetry source provenance and freshness metadata', () => {
    const detail = sourceDetail({
      source: 'tool_metric',
      entry_count: 7,
      exists: true,
      latest_age_s: 42,
      health: 'stale',
      stale_reason: 'freshness_slo_exceeded',
      freshness_slo_s: 300,
      producer: 'Telemetry_unified.summary_json',
      durable_store: '.masc/tool_metrics/YYYY-MM/DD.jsonl',
      dashboard_surface: '/api/v1/dashboard/telemetry/summary',
    })

    expect(detail).toContain('last 42s ago')
    expect(detail).toContain('stale: freshness_slo_exceeded')
    expect(detail).toContain('SLO 5m 0s')
    expect(detail).toContain('producer Telemetry_unified.summary_json')
    expect(detail).toContain('store .masc/tool_metrics/YYYY-MM/DD.jsonl')
    expect(detail).toContain('surface /api/v1/dashboard/telemetry/summary')
  })
})

describe('buildFleetRows runtime labels', () => {
  it('redacts model/provider identity while keeping lane outcome evidence', () => {
    const [row] = buildFleetRows([
      {
        name: 'runtime-keeper',
        status: 'active',
        keepalive_running: true,
        runtime_id: 'oas-keeper_unified',
        runtime_canonical: 'primary',
        active_model_label: 'codex-cli:auto',
        trust: {
          execution_summary: {
            provider_selected_model: 'anthropic:claude-sonnet',
            provider_attempt_count: 2,
            provider_fallback_applied: true,
            runtime_outcome: 'passed_to_next_model',
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
            model_used: 'anthropic:claude-sonnet',
            cost_usd: 0,
            handoff_to_model: null,
            handoff_new_generation: null,
            prompt_fingerprint: null,
            prompt_metrics: null,
            ctx_composition: null,
            input_tokens: null,
            output_tokens: null,
            total_tokens: null,
            wall_tokens_per_second: null,
            inference_telemetry: null,
            runtime_id: 'primary',
            runtime_selected_model: 'anthropic:claude-sonnet',
            runtime_attempt_count: 2,
            runtime_outcome: 'passed_to_next_model',
            runtime_strategy: 'round_robin',
            fallback_applied: true,
            fallback_hops: 1,
            fallback_from: 'openai:gpt-5.4',
            fallback_to: 'anthropic:claude-sonnet',
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
      model: 'runtime',
      runtime_label: 'oas-keeper_unified -> primary',
      provider_label: 'passed_to_next_model · 2 attempts · fallback',
      fallback_label: 'fallback · turn_timeout · 1 hops',
    })
  })

  it('does not fabricate a runtime model label when model evidence is absent', () => {
    const [row] = buildFleetRows([
      {
        name: 'unknown-model-keeper',
        status: 'active',
        keepalive_running: true,
      },
    ], EMPTY_TOOL_QUALITY)

    expect(row?.model).toBe('unknown')
  })

  it('projects the keeper stop_cause into fleet rows', () => {
    const [row] = buildFleetRows([
      {
        name: 'blocked-keeper',
        status: 'active',
        keepalive_running: true,
        stop_cause: {
          code: 'runtime_exhausted',
          source: 'runtime_blocker_class',
          label: 'no tool capable provider',
          summary: 'no provider can satisfy tool surface',
          severity: 'warn',
          next_action: 'inspect_provider_tool_contract',
        },
      },
    ], EMPTY_TOOL_QUALITY)

    expect(row?.stop_cause).toMatchObject({
      code: 'runtime_exhausted',
      source: 'runtime_blocker_class',
      summary: 'no provider can satisfy tool surface',
    })
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

  // Lock the remaining offline-trigger status strings in fleetBand's
  // production code. `'offline'` has an active producer
  // (historical dashboard monitor producer, dashboard_mission_agents.ml:206,
  // keeper_status_runtime.ml:276/353); `'unbooted'` is defensive (no
  // current OCaml producer, but the production check is load-bearing
  // for non-OCaml producers or future runtime states). Per
  // feedback_dead_defensive_cleanup_must_check_test_lock memory, lock
  // the defensive arm explicitly rather than treating it as dead.
  it.each([
    'offline',
    'unbooted',
  ])('classifies offline for status=%s', (status) => {
    expect(fleetBand(makeRow({ status }))).toBe('offline')
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
    expect(fleetBand(makeRow({ runtime_blocker_class: 'provider_runtime_error' }))).toBe('attention')
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
    const attention = makeRow({ runtime_blocker_class: 'provider_runtime_error' })
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

  // Lock the remaining offline-trigger status strings in statusClass.
  // Mirrors the fleetBand offline-trigger set (5 statuses); the
  // 'unbooted' arm is defensive (no current OCaml producer) per the
  // feedback_dead_defensive_cleanup_must_check_test_lock memory pattern.
  it.each([
    'offline',
    'unbooted',
    'dead',
    'crashed',
  ])('returns bad-light for status=%s', (status) => {
    expect(statusClass(makeRow({ status }))).toContain('var(--bad-light)')
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
      makeRow({ name: 'b', keepalive_running: true, context_ratio: PRESSURE_HOT_RATIO, last_activity_ago_s: 60, tool_calls: 0, recent_tools: [], tool_activity_known: false }),
      makeRow({ name: 'c', keepalive_running: false, context_ratio: 0.1, last_activity_ago_s: null, tool_calls: 0, recent_tools: [], tool_activity_known: false }),
    ]
    const counts = summaryCounts(rows)
    expect(counts.live).toBe(2)
    expect(counts.hot).toBe(1)
    expect(counts.toolTelemetryCovered).toBe(1)
    expect(counts.toolActive).toBe(1)
    expect(counts.toolQuiet).toBe(0)
    expect(counts.toolUnknown).toBe(2)
  })

  it('counts known quiet tool telemetry as covered, not active', () => {
    const counts = summaryCounts([
      makeRow({ name: 'quiet', tool_calls: 0, recent_tools: [], tool_activity_known: true }),
      makeRow({ name: 'unknown', tool_calls: 0, recent_tools: [], tool_activity_known: false }),
    ])

    expect(counts.toolTelemetryCovered).toBe(1)
    expect(counts.toolActive).toBe(0)
    expect(counts.toolQuiet).toBe(1)
    expect(counts.toolUnknown).toBe(1)
  })

  it('formats tool telemetry coverage detail for operator summaries', () => {
    const counts = summaryCounts([
      makeRow({ name: 'active', tool_calls: 2, recent_tools: ['masc_status'], tool_activity_known: true }),
      makeRow({ name: 'quiet', tool_calls: 0, recent_tools: [], tool_activity_known: true }),
      makeRow({ name: 'unknown', tool_calls: 0, recent_tools: [], tool_activity_known: false }),
    ])

    expect(toolTelemetryCoverageDetail(counts, 3)).toBe('도구 telemetry 확인 2/3 · 활동 1 · 기록 없음 1 · 미확인 1')
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
  it('warns about runtime blockers', () => {
    const rows = [makeRow({ runtime_blocker_class: 'turn_timeout' })]
    const warnings = buildRuntimeWarnings(rows)
    expect(warnings.length).toBe(1)
    expect(warnings[0]).toContain('runtime blockers')
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
