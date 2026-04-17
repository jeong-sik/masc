import { describe, it, expect } from 'vitest'
import { providerTone, modelMetricTone, fmtCost, fmtSuccessRate, fmtNumber, filterModelMetrics } from './runtime-monitor'
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

// ── providerTone ──

describe('providerTone', () => {
  it('returns bad when available is false', () => {
    expect(providerTone(makeProvider({ available: false }))).toBe('bad')
  })

  it('returns warn when discovery is not healthy', () => {
    expect(providerTone(makeProvider({ available: true, discovery: { healthy: false } }))).toBe('warn')
  })

  it('returns ok when available is true and healthy', () => {
    expect(providerTone(makeProvider({ available: true, discovery: { healthy: true } }))).toBe('ok')
  })

  it('returns ok when available is true without discovery', () => {
    expect(providerTone(makeProvider({ available: true }))).toBe('ok')
  })

  it('returns warn when available is undefined', () => {
    expect(providerTone(makeProvider())).toBe('warn')
  })

  it('returns warn when available is true but discovery is null', () => {
    expect(providerTone(makeProvider({ available: true, discovery: null }))).toBe('ok')
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
