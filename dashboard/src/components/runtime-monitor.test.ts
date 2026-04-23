import { describe, it, expect } from 'vitest'
import { runtimeProviderTone, modelMetricTone, fmtCost, fmtSuccessRate, fmtNumber, filterModelMetrics, sortModelMetricsByUrgency, metricCoverageText } from './runtime-monitor'
import type { DashboardRuntimeProviderSnapshot, DashboardRuntimeModelMetric } from '../api/dashboard'

function makeProvider(overrides: Partial<DashboardRuntimeProviderSnapshot> = {}): DashboardRuntimeProviderSnapshot {
  return {
    provider: 'test-provider',
    models: [],
    ...overrides,
  }
}

function makeMetric(overrides: Partial<DashboardRuntimeModelMetric> = {}): DashboardRuntimeModelMetric {
  return {
    model_id: 'test-model',
    ...overrides,
  }
}

// ── runtimeProviderTone ──

describe('runtimeProviderTone', () => {
  it('prefers backend-advertised missing_auth over optimistic booleans', () => {
    expect(
      runtimeProviderTone(
        makeProvider({
          status: 'missing_auth',
          available: true,
          discovery: { healthy: true },
        }),
      ),
    ).toBe('bad')
  })

  it('treats vertex_adc as warn because inventory is visible but run is disabled', () => {
    expect(
      runtimeProviderTone(
        makeProvider({
          status: 'vertex_adc',
          available: true,
          discovery: { healthy: true },
        }),
      ),
    ).toBe('warn')
  })

  it('treats unsupported backend status as bad', () => {
    expect(runtimeProviderTone(makeProvider({ status: 'unsupported' }))).toBe('bad')
  })

  it('returns bad when available is false', () => {
    expect(runtimeProviderTone(makeProvider({ available: false }))).toBe('bad')
  })

  it('returns warn when discovery is not healthy', () => {
    expect(runtimeProviderTone(makeProvider({ available: true, discovery: { healthy: false } }))).toBe('warn')
  })

  it('returns ok when available is true and healthy', () => {
    expect(runtimeProviderTone(makeProvider({ available: true, discovery: { healthy: true } }))).toBe('ok')
  })

  it('returns ok when available is true without discovery', () => {
    expect(runtimeProviderTone(makeProvider({ available: true }))).toBe('ok')
  })

  it('returns warn when available is undefined', () => {
    expect(runtimeProviderTone(makeProvider())).toBe('warn')
  })

  it('returns ok when available is true but discovery is null', () => {
    expect(runtimeProviderTone(makeProvider({ available: true, discovery: null }))).toBe('ok')
  })
})

// ── modelMetricTone ──

describe('modelMetricTone', () => {
  it('returns warn when entry_count is 0', () => {
    expect(modelMetricTone(makeMetric({ entry_count: 0 }))).toBe('warn')
  })

  it('returns warn when entry_count is undefined', () => {
    expect(modelMetricTone(makeMetric())).toBe('warn')
  })

  it('returns bad when success rate below 85%', () => {
    expect(modelMetricTone(makeMetric({ entry_count: 100, success_count: 80, error_count: 20 }))).toBe('bad')
  })

  it('returns warn when success rate between 85-95%', () => {
    expect(modelMetricTone(makeMetric({ entry_count: 100, success_count: 90, error_count: 10 }))).toBe('warn')
  })

  it('returns ok when success rate above 95%', () => {
    expect(modelMetricTone(makeMetric({ entry_count: 100, success_count: 96, error_count: 4 }))).toBe('ok')
  })

  it('returns warn when fallback_count > 0', () => {
    expect(modelMetricTone(makeMetric({ entry_count: 10, success_count: 10, error_count: 0, fallback_count: 1 }))).toBe('warn')
  })

  it('returns ok when all good and no fallbacks', () => {
    expect(modelMetricTone(makeMetric({ entry_count: 10, success_count: 10, error_count: 0, fallback_count: 0 }))).toBe('ok')
  })

  it('uses entry_count as fallback for success_count', () => {
    expect(modelMetricTone(makeMetric({ entry_count: 10, error_count: 0 }))).toBe('ok')
  })
})

// ── fmtCost ──

describe('fmtCost', () => {
  it('returns -- for undefined', () => {
    expect(fmtCost(undefined)).toBe('--')
  })

  it('returns -- for null', () => {
    expect(fmtCost(null)).toBe('--')
  })

  it('returns -- for NaN', () => {
    expect(fmtCost(NaN)).toBe('--')
  })

  it('returns $0 for zero', () => {
    expect(fmtCost(0)).toBe('$0')
  })

  it('formats small values with 4 decimals', () => {
    expect(fmtCost(0.005)).toBe('$0.0050')
  })

  it('formats regular values with 2 decimals', () => {
    expect(fmtCost(1.5)).toBe('$1.50')
  })

  it('formats large values with 2 decimals', () => {
    expect(fmtCost(123.456)).toBe('$123.46')
  })
})

// ── fmtSuccessRate ──

describe('fmtSuccessRate', () => {
  it('returns -- when total is 0', () => {
    expect(fmtSuccessRate(makeMetric({ success_count: 0, error_count: 0 }))).toBe('--')
  })

  it('returns -- when counts are undefined', () => {
    expect(fmtSuccessRate(makeMetric())).toBe('--')
  })

  it('formats 100% success', () => {
    expect(fmtSuccessRate(makeMetric({ success_count: 100, error_count: 0 }))).toBe('100.0%')
  })

  it('formats partial success', () => {
    expect(fmtSuccessRate(makeMetric({ success_count: 75, error_count: 25 }))).toBe('75.0%')
  })

  it('uses entry_count as fallback for success_count', () => {
    expect(fmtSuccessRate(makeMetric({ entry_count: 50, error_count: 0 }))).toBe('100.0%')
  })
})

// ── fmtNumber ──

describe('fmtNumber', () => {
  it('returns -- for undefined', () => {
    expect(fmtNumber(undefined)).toBe('--')
  })

  it('returns -- for null', () => {
    expect(fmtNumber(null)).toBe('--')
  })

  it('returns -- for NaN', () => {
    expect(fmtNumber(NaN)).toBe('--')
  })

  it('formats integer with ko-KR', () => {
    const result = fmtNumber(1234)
    expect(result).toContain('1,234')
  })

  it('formats with custom digits', () => {
    const result = fmtNumber(1234.567, 2)
    expect(result).toContain('1,234.57')
  })
})

describe('metricCoverageText', () => {
  it('returns null when all successful entries reported usage and telemetry', () => {
    expect(
      metricCoverageText(
        makeMetric({
          success_count: 3,
          usage_sample_count: 3,
          telemetry_sample_count: 3,
        }),
      ),
    ).toBeNull()
  })

  it('renders partial coverage when usage or telemetry samples are missing', () => {
    expect(
      metricCoverageText(
        makeMetric({
          coverage_status: 'partial',
          primary_coverage_stage: 'oas',
          primary_coverage_reason: 'missing_usage',
          success_count: 5,
          usage_sample_count: 0,
          telemetry_sample_count: 2,
        }),
      ),
    ).toBe('coverage partial · OAS · usage missing · usage 0/5 · telemetry 2/5')
  })

  it('renders error-only windows explicitly', () => {
    expect(
      metricCoverageText(
        makeMetric({
          coverage_status: 'error_only',
          success_count: 0,
          error_count: 3,
        }),
      ),
    ).toBe('error-only window')
  })
})

// ── filterModelMetrics ──

describe('filterModelMetrics', () => {
  const sample: readonly DashboardRuntimeModelMetric[] = [
    makeMetric({ model_id: 'groq:openai/gpt-oss-120b', top_tools: [{ tool: 'read_file', count: 3 }] }),
    makeMetric({ model_id: 'anthropic:claude-opus-4', top_tools: [{ tool: 'Bash', count: 5 }] }),
    makeMetric({ model_id: 'ollama:qwen3-coder-30b', top_tools: [] }),
  ]

  it('returns input reference unchanged for empty query', () => {
    const result = filterModelMetrics(sample, '')
    expect(result).toBe(sample)
  })

  it('returns input reference unchanged for whitespace-only query', () => {
    const result = filterModelMetrics(sample, '   ')
    expect(result).toBe(sample)
  })

  it('matches on model_id substring', () => {
    const result = filterModelMetrics(sample, 'gpt-oss')
    expect(result.map(m => m.model_id)).toEqual(['groq:openai/gpt-oss-120b'])
  })

  it('matches on top_tools[].tool name substring', () => {
    const result = filterModelMetrics(sample, 'read_file')
    expect(result.map(m => m.model_id)).toEqual(['groq:openai/gpt-oss-120b'])
  })

  it('is case-insensitive', () => {
    const result = filterModelMetrics(sample, 'BASH')
    expect(result.map(m => m.model_id)).toEqual(['anthropic:claude-opus-4'])
  })

  it('trims leading/trailing whitespace from query', () => {
    const result = filterModelMetrics(sample, '  qwen3  ')
    expect(result.map(m => m.model_id)).toEqual(['ollama:qwen3-coder-30b'])
  })

  it('returns empty array when no match', () => {
    const result = filterModelMetrics(sample, 'nonexistent-xyz')
    expect(result).toHaveLength(0)
  })

  it('does not mutate input array', () => {
    const before = sample.map(m => m.model_id)
    filterModelMetrics(sample, 'groq')
    const after = sample.map(m => m.model_id)
    expect(after).toEqual(before)
  })

  it('handles null top_tools safely', () => {
    const data: readonly DashboardRuntimeModelMetric[] = [
      makeMetric({ model_id: 'x:y', top_tools: null }),
    ]
    const result = filterModelMetrics(data, 'x:y')
    expect(result).toHaveLength(1)
  })
})

// ── sortModelMetricsByUrgency ──

describe('sortModelMetricsByUrgency', () => {
  it('puts models with more errors first', () => {
    const sample = [
      makeMetric({ model_id: 'healthy', entry_count: 50, success_count: 50, error_count: 0 }),
      makeMetric({ model_id: 'broken', entry_count: 11, success_count: 0, error_count: 11 }),
      makeMetric({ model_id: 'flaky', entry_count: 10, success_count: 7, error_count: 3 }),
    ]
    const result = sortModelMetricsByUrgency(sample)
    expect(result.map(m => m.model_id)).toEqual(['broken', 'flaky', 'healthy'])
  })

  it('breaks ties on error_count by entry_count desc', () => {
    const sample = [
      makeMetric({ model_id: 'idle', entry_count: 0, error_count: 0 }),
      makeMetric({ model_id: 'busy', entry_count: 100, success_count: 100, error_count: 0 }),
      makeMetric({ model_id: 'medium', entry_count: 20, success_count: 20, error_count: 0 }),
    ]
    const result = sortModelMetricsByUrgency(sample)
    expect(result.map(m => m.model_id)).toEqual(['busy', 'medium', 'idle'])
  })

  it('prioritizes coverage gaps ahead of healthy full-coverage models', () => {
    const sample = [
      makeMetric({ model_id: 'full', entry_count: 100, success_count: 100, coverage_status: 'full' }),
      makeMetric({ model_id: 'partial', entry_count: 5, success_count: 5, coverage_status: 'partial' }),
      makeMetric({ model_id: 'missing', entry_count: 2, success_count: 2, coverage_status: 'none' }),
    ]
    const result = sortModelMetricsByUrgency(sample)
    expect(result.map(m => m.model_id)).toEqual(['missing', 'partial', 'full'])
  })

  it('falls back to model_id alpha order when everything else is equal', () => {
    const sample = [
      makeMetric({ model_id: 'zebra', entry_count: 5, success_count: 5, error_count: 0 }),
      makeMetric({ model_id: 'alpha', entry_count: 5, success_count: 5, error_count: 0 }),
    ]
    const result = sortModelMetricsByUrgency(sample)
    expect(result.map(m => m.model_id)).toEqual(['alpha', 'zebra'])
  })

  it('does not mutate the input array', () => {
    const sample: readonly DashboardRuntimeModelMetric[] = [
      makeMetric({ model_id: 'a', error_count: 0 }),
      makeMetric({ model_id: 'b', error_count: 10 }),
    ]
    const before = sample.map(m => m.model_id)
    sortModelMetricsByUrgency(sample)
    expect(sample.map(m => m.model_id)).toEqual(before)
  })

  it('treats undefined error_count / entry_count as 0', () => {
    const sample = [
      makeMetric({ model_id: 'unknown' }),
      makeMetric({ model_id: 'with-errors', error_count: 1 }),
    ]
    const result = sortModelMetricsByUrgency(sample)
    expect(result.map(m => m.model_id)).toEqual(['with-errors', 'unknown'])
  })
})
